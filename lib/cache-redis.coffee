Promise       = require 'bluebird'
using         = Promise.using
log           = require 'simplog'
EventEmitter  = require 'events'
_             = require 'lodash'
ReadWriteLock = require 'rwlock'
redis         = require("redis");
{ Readable }  = require("stream")
{ promisify } = require("util");


config  = require './config.coffee'
client = redis.createClient()
getItemFromCache = promisify(client.get).bind(client);
putItemInCache = promisify(client.set).bind(client);
deleteItemInCache = promisify(client.del).bind(client);

readWriteLock = new ReadWriteLock()

# just a counter to help us create unique file names
tempCounter = 0
cacheEventEmitter = new EventEmitter()
lockMap = {}
# an arbitrary, but larger than default, max listener count
# It really shouldn't ever be hit but I kind of feel like we want to know if we
# have a shitload of cache waiters backed up and this 'll blow it up so we
# can see
cacheEventEmitter.setMaxListeners(1000)

getCacheEntry = (cacheKey) ->
  new Promise (resolve, reject) ->
    getItemFromCache(cacheKey)
      .then( (cachedValue) -> resolve(cachedValue) )
      .catch( () -> resolve(undefined))

deleteCacheEntry = (cacheKey) ->
  new Promise (resolve, reject) ->
    log.debug "deleting cache entry #{cacheKey}"
    deleteItemInCache(cacheKey)
      .then( () -> resolve() )
      .catch( (e) -> reject(e) )

cacheResponse = (cacheKey, response) ->
  new Promise (resolve, reject) ->
    cachedResponse = {
      statusCode: response.statusCode
      statusMessage: response.statusMessage
      headers: response.headers
      createTime: Date.now()
    }
    body = [];
    response.on('err', reject)
    response.on('data', (chunk) -> body.push(chunk) )
    response.on('end', () ->
      cachedResponse.body = Buffer.concat(body).toString();
      acquireWriteLock = () ->
        promise = new Promise (resolve, reject) ->
          readWriteLock.writeLock(cacheKey, (release) -> resolve(release))
        promise.disposer (release, promise) -> release()
      # we have the whole body, now we just need to store things and emit the appropriate events
      using(acquireWriteLock(), () ->
        log.debug "caching response for #{cacheKey}"
        putItemInCache(cacheKey, JSON.stringify(cachedResponse))
        .then( () -> cacheEventEmitter.emit("#{cacheKey}"))
        .then( () -> log.debug "response (#{JSON.stringify cachedResponse}) for #{cacheKey} has been written to cache")
        .then( () -> resolve )
        .catch((e) ->
          log.error "error caching response keyed (#{cacheKey}), #{e}"
          cacheEventEmitter.emit("#{cacheKey}", e);
          reject(e);
        )
      );
    );

tryGetCachedResponse = (cacheKey) ->
  new Promise (resolve, reject) ->
    log.debug "tryGetCachedResponse(#{cacheKey})"
    getItemFromCache(cacheKey)
    .then( (cachedValue) ->
      if (cachedValue) 
        cachedResponse = JSON.parse(cachedValue)
        cachedResponse.dispose = () ->
        cachedResponse.body = Readable.from([cachedResponse.body])
        resolve(cachedResponse)
      else
        return resolve(undefined);
    )
    .catch((e) -> 
      # if we have a problem reading the cache, we just return nothing
      # because... we couldn't read anything
      log.debug "error fetching cache item #{cacheKey} #{e.message}"
      resolve undefined
    )

addCachedResponseToContext = (context, cachedResponse) ->
  return unless cachedResponse
  log.debug "adding cached response #{cachedResponse} to context"
  context.cachedResponse?.dispose()
  context.contextEvents.on 'clientdisconnect', cachedResponse.dispose
  context.contextEvents.on 'responsefinish', cachedResponse.dispose
  context.cachedResponse = cachedResponse

removeCachedResponseFromContext = (context) ->
  return unless context.cachedResponse
  context.contextEvents.removeListener 'clientdisconnect', context.cachedResponse.dispose
  context.contextEvents.removeListener 'responsefinish', context.cachedResponse.dispose
  context.cachedResponse.dispose()
  context.cachedResponse = undefined

promiseToGetCacheLock = (cacheKey) ->
  return new Promise (resolve, reject) ->
    resolve(null) if lockMap[cacheKey]
    lockMap[cacheKey] =  true
    resolve(cacheKey)

promiseToReleaseCacheLock = (lockDescriptor) ->
  new Promise (resolve, reject) ->
    delete lockMap[lockDescriptor]
    resolve()

module.exports.tryGetCachedResponse = tryGetCachedResponse
module.exports.cacheResponse = cacheResponse
module.exports.getCacheEntry = getCacheEntry
module.exports.deleteCacheEntry = deleteCacheEntry
module.exports.promiseToGetCacheLock = promiseToGetCacheLock
module.exports.promiseToReleaseCacheLock = promiseToReleaseCacheLock
module.exports.events = cacheEventEmitter
module.exports.addCachedResponseToContext = addCachedResponseToContext
module.exports.removeCachedResponseFromContext = removeCachedResponseFromContext
