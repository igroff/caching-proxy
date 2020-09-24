Promise       = require 'bluebird'
using         = Promise.using
fs            = Promise.promisifyAll(require('fs'))
path          = require 'path'
log           = require 'simplog'
EventEmitter  = require 'events'
_             = require 'lodash'
ReadWriteLock = require 'rwlock'

config  = require './config.coffee'
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

tryGetCachedResponse = (cacheKey) ->
  new Promise (resolve, reject) ->
    log.debug "tryGetCachedResponse(#{cacheKey})"
    [cacheFilePath, cacheBodyFilePath] = getCacheFilePath cacheKey
    fs.statAsync(cacheFilePath)
    .then () ->
      fs.statAsync(cacheBodyFilePath)
    .then (stats) ->
      log.debug "cacheFilePath #{cacheFilePath}"
      log.debug "cacheBodyFilePath #{cacheBodyFilePath}"
      Promise.all([fs.readFileAsync(cacheFilePath, encoding: 'utf8'), stats])
    .then (r) ->
      data = r[0]
      stats = r[1]
      log.debug "cacheFileData: #{data}"
      lines = data.split('\n')
      cacheResponse = {}
      cacheResponse.statusCode = Number(lines[0])
      cacheResponse.statusMessage = lines[1]
      cacheResponse.headers = JSON.parse(lines[2])
      cacheResponse.createTime = stats.ctime.getTime()
      cacheResponse.body = fs.createReadStream(cacheBodyFilePath)
      cacheResponse.body.on 'error', (e) -> log.error "error from cached response stream %s cache key %s", e, cacheKey
      readWriteLock.readLock cacheKey, (release) ->
        # using an undocumented method that indeed does what we need it to do
        # which is: close the fd
        cacheResponse.dispose = _.once =>
          cacheResponse.body.close()
          cacheResponse.isDisposed = true
          release()
        resolve cacheResponse
    .catch (e) ->
      # if we have a problem reading the cache, we just return nothing
      # because... we couldn't read anything
      log.debug "error opening cache file #{cacheFilePath} #{e.message}"
      resolve undefined

addCachedResponseToContext = (context, cachedResponse) ->
  return unless cachedResponse
  context.cachedResponse?.dispose()
  context.contextEvents.on 'clientdisconnect', cachedResponse.dispose
  context.contextEvents.on 'responsefinish', cachedResponse.dispose
  context.cachedResponse = cachedResponse

removeCachedResponseFromContext = (context) ->
  return unless context.cachedResponse
  context.contextEvents.removeListener 'clientdisconnect', context.cachedResponse.dispose
  context.contextEvents.removeListener 'responsefinish', context.cachedResponse.dispose
  context.cachedResponse?.dispose()
  context.cachedResponse = undefined

getCacheFilePath = (requestInfo) ->
  uniqueIdentifier = "#{process.pid}.#{new Date().getTime()}.#{++tempCounter}"
  cacheFilePath = path.join(config.cacheDir, requestInfo)
  cacheFileTempPath = path.join(config.tempDir, "#{requestInfo}.#{uniqueIdentifier}")
  return [cacheFilePath, "#{cacheFilePath}.body", cacheFileTempPath, "#{cacheFileTempPath}.body"]

deleteCacheEntry = (cacheKey) ->
  [cacheFilePath] = getCacheFilePath cacheKey
  log.debug "deleting cache file #{cacheFilePath}"
  fs.unlinkAsync(cacheFilePath)
  .catch( (e) ->
    # it's cool if we get asked to delete a chache entry that isn't there but if we get
    # anything else, we want it to bubble up
    if e.message.indexOf("ENOENT") is -1
      throw e
  )

cacheResponse = (cacheKey, response) ->
  new Promise (resolve, reject) ->
    [cacheFilePath, cacheBodyFilePath, cacheFileTempPath, cacheBodyFileTempPath] = getCacheFilePath cacheKey
    log.debug "caching response metadata to #{cacheFilePath}, and body to #{cacheBodyFilePath}"
    metadataStream = fs.createWriteStream(cacheFileTempPath, {flag: 'w', defaultEncoding: 'utf8'})
    promiseForMetadataFileToEndWrite = new Promise (resolve, reject) ->
      metadataStream.on 'finish', resolve
      metadataStream.on 'error', reject
    metadataStreamCloser = _.once => metadataStream.close()
    metadataStream.write("#{response.statusCode}\n")
    metadataStream.write("#{response.statusMessage}\n")
    metadataStream.write("#{JSON.stringify response.headers}\n")
    metadataStream.end()
    bodyCacheWriteStream = fs.createWriteStream(cacheBodyFileTempPath, {flat: 'w', defaultEncoding: 'utf8'})
    bodyCacheWriteStreamCloser = _.once => bodyCacheWriteStream.close()
    response.pipe(bodyCacheWriteStream)
    promiseForResponseToEnd = new Promise (resolve, reject) ->
      bodyCacheWriteStream.on 'finish', resolve
      bodyCacheWriteStream.on 'error', reject
      response.on 'error', reject
    acquireWriteLock = () ->
      promise = new Promise (resolve, reject) ->
        readWriteLock.writeLock(cacheKey, (release) -> resolve(release))
      promise.disposer (release, promise) -> release()
    # once the response is complete, we will have written (piped) out the response to the
    # temp file, all that remains is to move the temp files into place of the 'non temp' 
    # files
    writePipeline = () ->
      Promise.resolve()
      .then () -> promiseForMetadataFileToEndWrite
      .then () -> promiseForResponseToEnd
      .then () -> metadataStreamCloser()
      .then () -> bodyCacheWriteStreamCloser()
      .then () -> fs.renameAsync(cacheFileTempPath, cacheFilePath)
      .then () -> fs.renameAsync(cacheBodyFileTempPath, cacheBodyFilePath)
      .tap log.debug "response for #{cacheKey} has been written to cache"
      .then () -> cacheEventEmitter.emit("#{cacheKey}")
      .then resolve
      .catch( (e) ->
        cacheEventEmitter.emit "#{cacheKey}", e
        reject(e)
      )
    using(acquireWriteLock(), writePipeline)

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
module.exports.promiseToGetCacheLock = promiseToGetCacheLock
module.exports.promiseToReleaseCacheLock = promiseToReleaseCacheLock
module.exports.deleteCacheEntry = deleteCacheEntry
module.exports.events = cacheEventEmitter
module.exports.addCachedResponseToContext = addCachedResponseToContext
module.exports.removeCachedResponseFromContext = removeCachedResponseFromContext
