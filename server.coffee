#! /usr/bin/env node_modules/.bin/coffee
Promise       = require 'bluebird'
using         = Promise.using
http          = require 'http'
httpProxy     = require 'http-proxy'
EventEmitter  = require 'events'
log           = require 'simplog'
crypto        = require 'crypto'
mocks         = require 'node-mocks-http'

config        = require './lib/config.coffee'
cache         = require './lib/cache.coffee'
admin         = require './lib/admin_handlers.coffee'
buildContext  = require './lib/context.coffee'
 
proxy = httpProxy.createProxyServer({ws: true})

# this event is raised when we get a response from the proxied service
# it is here that we will cache responses, while it'd be awesome to do this
# another way this is currently the only way to get the response from
# http-proxy
proxy.on 'proxyRes', (proxyRes, request, res) ->
  log.debug "proxy response received for key: %s contextId %s", request.cacheKey, request.contextId
  # a configuration may specify that the response be cached, or simply proxied.
  # In the case of caching being desired a cacheKey will be present otherwise
  # there will be no cacheKey.  So, if no cache key, no caching has been requested
  #
  if request.cacheKey
    # so, if cacheNon200Response is true, we cache it all the time otherwise we only
    # cache responses with a status of 200
    shouldICacheIt = request.targetConfig.cacheNon200Response or proxyRes.statusCode is 200
    if shouldICacheIt
      console.log "status: ", proxyRes.statusCode
      log.debug "proxy response received for key: %s contextid: %s url: %s previous cache: %s, disposed: %s", request.cacheKey, request.contextId, request.url, request.cachedResponse, request.cachedResponse?.isDisposed
      cache.cacheResponse(request.cacheKey, proxyRes)
    else
      log.debug "notifying end of cache cycle"
      cache.events.emit(request.cacheKey)

class RequestHandlingComplete extends Error
  constructor: (@stepOrMessage="") ->
    @requestHandlingComplete = true
    super()

noteStartTime = (context) ->
  now = new Date()
  context.requestStartTime = now.getTime()
  context.startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  return context

setDebugIfAskedFor = (context) ->
  log.debug "setDebugIfAskedFor"
  return context unless context.isDebugRequest
  context.originalDebugValue = process.env.DEBUG
  log.debug "isDebugRequest: #{context.isDebugRequest}"
  process.env.DEBUG = true
  return context

determineIfAdminRequest = (context) ->
  log.debug "determineIfAdminRequest"
  adminRequestInfo = admin.getAdminRequestInfo(context.request)
  if adminRequestInfo
    context.isAdminRequest = true
    context.adminCommand = adminRequestInfo[0]
    context.url = adminRequestInfo[1]
    [context.pathOnly, context.queryString] = context.url.split('?')
    log.debug "we have an admin request command '%s' and url '%s'", context.adminCommand, context.url
  return context

getTargetConfigForRequest = (context) ->
    log.debug "getTargetConfigForRequest"
    context.targetConfig = config.findMatchingTarget(context.url)
    log.debug "target config: %j", context.targetConfig
    return context

stripPathIfRequested = (context) ->
  return context if context.targetConfig.sendPathWithProxiedRequest
  log.debug "stripPathIfRequested"
  context.url = ""
  return context

determineIfProxiedOnlyOrCached = (context) ->
  log.debug "determineIfProxiedOnlyOrCached"
  # if we have no valid life span specified for a cache, we can't cache it
  # so if our cache configurations are values < 0, we'll make the request
  # proxy only
  if context.targetConfig.maxAgeInMilliseconds < 1
    context.isProxyOnly = true
  else if context.targetConfig.dayRelativeExpirationTimeInMilliseconds < 1
    context.isProxyOnly = true
  # admin requests are NEVER proxy only 
  if context.isAdminRequest
    context.isProxyOnly = false
  return context

handleProxyOnlyRequest = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) unless context.isProxyOnly
    log.debug "handleProxyOnlyRequest"
    proxyError = (e) ->
      log.error "error during proxy only request"
      reject(e)
    context.contextEvents.once 'responsefinish', () ->
      #This one is a bit odd, because if we proxy the request, we're done that's all there is to do
      reject new RequestHandlingComplete()
    proxy.web(context.request, context.response, { target: context.targetConfig.target, headers: context.targetConfig.headers}, proxyError)

readRequestBody = (context) ->
  new Promise (resolve, reject) ->
    # we don't need the body for proxy only requests, it will simply be forwarded to the target
    return resolve(context) if context.isProxyOnly
    log.debug "readRequestBody"
    context.requestBody = ""
    context.request.on 'data', (data) -> context.requestBody += data
    context.request.once 'end', () -> resolve(context)
    context.request.once 'error', reject

buildCacheKey = (context) ->
  log.debug "buildCacheKey"
  # build a cache key
  cacheKeyData = "#{context.method}-#{context.pathOnly}-#{context.queryString or ''}-#{context.requestBody or ""}"
  log.debug "request cache key data: #{cacheKeyData}"
  context.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
  log.debug "request cache key: #{context.cacheKey}"
  return context

handleAdminRequest = (context) ->
  # no admin command means it's not an admin request
  return context if not context.adminCommand
  log.debug "handleAdminRequest"
  admin.requestHandler context
  # admin 'stuff' is all handled in the admin handler so we're done here
  throw new RequestHandlingComplete()

getCachedResponse = (context) ->
  # nothing to do if there is no cache key
  return context if not context.cacheKey
  log.debug "getCachedResponse"
  cache.tryGetCachedResponse(context.cacheKey)
  .then (cachedResponse) ->
    cache.addCachedResponseToContext context, cachedResponse
    log.debug("no cached response for %s", context.cacheKey) unless context.cachedResponse
    return context

determineIfCacheIsExpired = (context) ->
  log.debug "determineIfCacheIsExpired"
  cachedResponse = context.cachedResponse
  return context unless cachedResponse
  # we start with the assumption that the cached response is not expired, and we prove otherwise
  # this err's on the side of serving the cached response as, if we have a cached response, the
  # expectation is that it will be served
  context.cachedResponseIsExpired = false
  if context.targetConfig.dayRelativeExpirationTimeInMilliseconds
    context.absoluteExpirationTime = context.startOfDay + context.targetConfig.dayRelativeExpirationTimeInMilliseconds
    absoluteRequestTimeInMs = context.requestStartTime - context.startOfDay
    log.debug "absolute expiration time: %s, now %s", context.targetConfig.dayRelativeExpirationTimeInMilliseconds, absoluteRequestTimeInMs
    # if the time of our request is more than the configured value of milliesconds past the start of the day
    # AND the cached response was created BEFORE the absolute expiration time we'll consider the cache expired
    context.cachedResponseIsExpired = ((absoluteRequestTimeInMs) > context.targetConfig.dayRelativeExpirationTimeInMilliseconds) and (cachedResponse.createTime < context.absoluteExpirationTime)
  else
    # if our cached response is older than is configured for the max age, then we'll
    # queue up a rebuild request BUT still serve the cached response
    log.debug "create time: %s, now %s, delta %s, maxAge: %s", cachedResponse.createTime, context.requestStartTime, context.requestStartTime - cachedResponse.createTime, context.targetConfig.maxAgeInMilliseconds
    context.cachedResponseIsExpired = context.requestStartTime - cachedResponse.createTime > context.targetConfig.maxAgeInMilliseconds
    log.debug "cachedResponseIsExpired: #{context.cachedResponseIsExpired}"
  return context

dumpCachedResponseIfStaleResponseIsNotAllowed = (context) ->
  # here's the deal, if we want a cached response to NEVER be served IF stale, the target config
  # will be configued with a falsey serveStaleCache, so in that case we'll just flat dump any
  # cached response we may have IF it is expired. We do it here before we get the cache lock
  # because we will need to acquire that ( if no one else has it ) as we'll be rebuilding it
  if not context.targetConfig.serveStaleCache and context.cachedResponseIsExpired
    log.debug "cached response expired, and our config specifies no serving stale cache items"
    # first we need to rid ourselves of the expired cached response, this has to happen here
    # because we're getting rid of it so we can load another ( or create another ) cached
    # response, which will ultimately itself be disposed of at the end of the response
    cache.removeCachedResponseFromContext context
    # and since we've just erased our cached response, we need to clear this
    context.cachedResponseIsExpired = false
  return context

getCacheLockIfNoCachedResponseExists = (context) ->
  return context if context.cachedResponse # we have a cached, response no need to lock anything
  log.debug "getCacheLockIfNoCachedResponseExists"
  cache.promiseToGetCacheLock(context.cacheKey)
  .then (lockDescriptor) ->
    context.cacheLockDescriptor = lockDescriptor
    return context

getAndCacheResponseIfNoneExists = (context) ->
  new Promise (resolve, reject) ->
    # get and cache a response for the given request, if there is already 
    # a cached response there is nothing to do
    return resolve(context) if context.cachedResponse
    log.debug "getAndCacheResponseIfNoneExists"
    reject new Error("need a cacheKey inorder to cache a response, none present") if not context.cacheKey
    responseCachedHandler = (e) ->
      log.debug "responseCacheHandler for contextId %d", context.contextId
      if e
        reject(e)
      else
        log.debug "loading cached response (%s), existing cached response: %s", context.cacheKey, context.cachedResponse
        cache.tryGetCachedResponse(context.cacheKey)
        .then (cachedResponse) ->
          cache.addCachedResponseToContext context, cachedResponse
          resolve(context)
        .catch (e) ->
          log.debug "error %s contextId %d", context.contextId, e
          reject(e)
    # if we've arrived here it's because the cached response didn't exist so we know we'll want to wait for one
    cache.events.once "#{context.cacheKey}", responseCachedHandler
    # only if we have the cache lock will we rebuild, otherwise someone else is
    # already rebuilding the cache matching this request
    if context.cacheLockDescriptor
      log.debug "we got cache lock %s for %s, triggering rebuild %d", context.cacheLockDescriptor, context.cacheKey, context.contextId
      fauxProxyResponse = mocks.createResponse()
      handleProxyError = (e) ->
        log.error "error proxying cache rebuild request to %s\n%s", context.targetConfig, e
        reject(e)
      proxy.web(context, fauxProxyResponse, { target: context.targetConfig.target, headers: context.targetConfig.headers }, handleProxyError)
    else
      log.debug "didn't get the cache lock for %s, waiting for in progress rebuild contextId %d", context.cacheKey, context.contextId

getCacheLockIfCacheIsExpired = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) unless context.cachedResponseIsExpired # if it's not expired, we have nothing to do
    log.debug "getCacheLockIfCacheIsExpired"
    cache.promiseToGetCacheLock(context.cacheKey)
    .then (lockDescriptor) ->
      # tight timing can lead us here when we already have a lock descriptor, so we want to make sure we don't overwrite
      # an existing lock descriptor, because we can end up here with a null value for the lockDescriptor
      context.cacheLockDescriptor = context.cacheLockDescriptor || lockDescriptor
      if lockDescriptor
        log.debug "got cache lock #{context.cacheLockDescriptor} for expired cache item #{context.contextId}"
      resolve(context)
    .catch reject

serveCachedResponse = (context) ->
  log.debug "serveCachedResponse"
  cachedResponse = context.cachedResponse
  cachedResponse.headers['x-cached-by-route'] = context.targetConfig.route
  cachedResponse.headers['x-cache-key'] = context.cacheKey
  cachedResponse.headers['x-cache-created'] = cachedResponse.createTime
  serveDuration = new Date().getTime() -  context.requestStartTime
  cachedResponse.headers['x-cache-serve-duration-ms'] = serveDuration
  context.response.writeHead cachedResponse.statusCode, cachedResponse.headers
  cachedResponse.body.pipe(context.response)
  context.contextEvents.once 'responsefinish', () ->
    log.info "%s cached response served in %d ms", context.request.url, serveDuration
  return context

triggerRebuildOfExpiredCachedResponse = (context) ->
  new Promise (resolve, reject) ->
    return reject new Error("no cached response found, cannot trigger rebuild") unless context.cachedResponse
    cachedResponse = context.cachedResponse
    if context.cachedResponseIsExpired and context.cacheLockDescriptor
      log.debug "triggerRebuildOfExpiredCachedResponse(%s)", context.cacheKey
      fauxProxyResponse = mocks.createResponse()
      handleProxyError = (e) ->
        log.error "error proxying cache rebuild request to %s\n%s", context.targetConfig.target, e
        reject(e)
      # while we don't actually need to wait for this response to be cached ( for the requestor ) because a
      # cached resopnse will have already been served, we do need to keep our pipeline going as expected
      # because we have a 'disposable' context that we use to manage this whole flow
      cache.events.once context.cacheKey, () -> resolve(context)
      return proxy.web(context, fauxProxyResponse, { target: context.targetConfig.target, headers: context.targetConfig.headers}, handleProxyError)
    resolve(context)

resetDebugIfAskedFor = (context) ->
  log.debug "resetDebugIfAskedFor"
  return context unless context.isDebugRequest
  process.env.DEBUG = context.originalDebugValue
  return context

server = http.createServer (request, response) ->
  log.debug "#{request.method} #{request.url}"
  getContextThatUnlocksCacheOnDispose = () ->
    buildContext(request, response).disposer (context, promise) ->
      # if we've lost our client, this is how we know and as such there is no 
      # sense in keeping the cached response around since we'll never serve it to anyone
      # normally we'd 
      cache.removeCachedResponseFromContext(context) if context.clientIsDisconnected
      log.debug "disposing of request %d", context.contextId
      if context.cacheLockDescriptor
        log.debug "unlocking cache lock %s during context dispose %d", context.cacheLockDescriptor, context.contextId
        cache.promiseToReleaseCacheLock(context.cacheLockDescriptor)
      else
        log.debug "cache not locked, no unlock needed during context dispose"

  requestPipeline = (context) ->
    Promise.resolve(context)
    .then noteStartTime
    .then setDebugIfAskedFor
    .then determineIfAdminRequest
    .then getTargetConfigForRequest
    .then stripPathIfRequested
    .then determineIfProxiedOnlyOrCached
    .then handleProxyOnlyRequest
    .then readRequestBody
    .then buildCacheKey
    .then handleAdminRequest
    .then getCachedResponse
    .then determineIfCacheIsExpired
    .then dumpCachedResponseIfStaleResponseIsNotAllowed
    .then getCacheLockIfNoCachedResponseExists
    .then getAndCacheResponseIfNoneExists
    .then getCacheLockIfCacheIsExpired
    .then serveCachedResponse
    .then triggerRebuildOfExpiredCachedResponse
    .then resetDebugIfAskedFor
    .tap -> log.debug("request handling complete")
    .catch RequestHandlingComplete, (e) ->
      log.debug "request handling completed in catch"
    .catch (e) ->
      log.error "error processing request"
      log.error e.stack
      response.writeHead 500, {}
      response.end('{"status": "error", "message": "' + e.message + '"}')
  using(getContextThatUnlocksCacheOnDispose(), requestPipeline)

log.info "listening on port %s", config.listenPort
log.info "configuration: %j", config
log.debug "debug logging enabled"

proxyWebsocket = (context) ->
  proxy.ws(context.request, context.socket, context.head, { target: context.targetConfig.target, xfwd: true, headers: context.targetConfig.headers})
  return context
# websockets can be proxied, but they are not cached as that would be a whole giant ball of nasty
# however they are configued similarly to 'normal' HTTP targets
server.on 'upgrade', (request, socket, head) ->
  buildContext(request, null)
  .then (context) ->
    context.socket = socket
    context.head = head
    context
  .then getTargetConfigForRequest
  .then proxyWebsocket

server.listen(config.listenPort).setTimeout(config.requestTimeout * 1000)
