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
 
proxy = httpProxy.createProxyServer({})

# this event is raised when we get a response from the proxied service
# it is here that we will cache responses, while it'd be awesome to do this
# another way this is currently the only way to get the response from
# http-proxy
proxy.on 'proxyRes', (proxyRes, request, res) ->
  log.debug "proxy response received for key: #{request.cacheKey}"
  # a configuration may specify that the response be cached, or simply proxied.
  # In the case of caching being desired a cacheKey will be present otherwise
  # there will be no cacheKey.  So, if no cache key, no caching has been requested
  if request.cacheKey
    cache.cacheResponse(request.cacheKey, proxyRes)
    .then( -> request.proxiedResponseCached and request.proxiedResponseCached())

class RequestHandlingComplete extends Error
  constructor: (@stepOrMessage="") ->
    @requestHandlingComplete = true
    super()

determineIfAdminRequest = (context) ->
  new Promise (resolve, reject) ->
    log.debug "determineIfAdminRequest"
    adminRequestInfo = admin.getAdminRequestInfo(context.request)
    if adminRequestInfo
      log.debug "we have an admin request command and url are #{adminRequestInfo}"
      context.adminCommand = adminRequestInfo[0]
      context.url = adminRequestInfo[1]
    resolve(context)

determineIfProxiedOnlyOrCached = (context) ->
  new Promise (resolve, reject) ->
    log.debug "determineIfProxiedOnlyOrCached"
    # the target config defines the proxy only vs. cache state of a
    # request
    # it's prossible to specify a proxy target in the request, this is intended to 
    # be used for testing configuration changes prior to setting them 'in stone' via
    # the config file, if the header is not present or an error is encountered while
    # parsing it, we'll go ahead an pick as normal
    headerConfig = context.request.headers['x-proxy-target-config']
    if headerConfig
      try
        context.targetConfig = JSON.parse(headerConfig)
      catch e
        reject new Error("error parsing target config from provided header: #{headerConfig}\n #{e.message}")
    # if there was no config in the header, then we'll go ahead and load the mathing config
    if not context.targetConfig
      context.targetConfig = config.findMatchingTarget(context.url)
    context.isProxyOnly = context.targetConfig.maxAgeInMilliseconds < 1
    resolve(context)

handleProxyOnlyRequest = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) unless context.isProxyOnly
    log.debug "handleProxyOnlyRequest"
    proxyError = (e) ->
      log.error "error during proxy only request"
      reject(e)
    context.response.on 'finish', () ->
      #This one is a bit odd, because if we proxy the request, we're done that's all there is to do
      reject new RequestHandlingComplete()
    proxy.web(context.request, context.response, { target: context.targetConfig.target }, proxyError)

readRequestBody = (context) ->
  new Promise (resolve, reject) ->
    # if this is not a cached request ( no proxy only requests should get here tho )
    # then there is no need to read the request body
    return resolve(context) if context.targetConfig.maxAgeInMilliseconds < 1
    log.debug "readRequestBody"
    context.requestBody = ""
    context.request.on 'data', (data) -> context.requestBody += data
    context.request.on 'end', () -> resolve(context)
    context.request.on 'error', reject

buildCacheKey = (context) ->
  new Promise (resolve, reject) ->
    # if there is no timeout, then there is no cache, and thus no need to create a 
    # cache key
    return resolve(context) if context.targetConfig.maxAgeInMilliseconds < 1
    log.debug "buildCacheKey"
    # build a cache key
    cacheKeyData = "#{context.request.method}-#{context.url}-#{context.requestBody or ""}"
    context.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
    log.debug "request cache key: #{context.cacheKey}"
    resolve(context)

handleAdminRequest = (context) ->
  new Promise (resolve, reject) ->
    # no admin command means it's not an admin request
    return resolve(context) if not context.adminCommand
    log.debug "handleAdminRequest"
    admin.requestHandler context
    # admin 'stuff' is all handled in the admin handler so we're done here
    reject new RequestHandlingComplete()

getCachedResponse = (context) ->
  new Promise (resolve, reject) ->
    # nothing to do if there is no cache key
    return resolve(context) if not context.cacheKey
    log.debug "getCachedResponse"
    cache.tryGetCachedResponse(context.cacheKey)
    .then (cachedResponse) ->
      context.cachedResponse = cachedResponse
      resolve(context)
    .catch reject

getCacheLockIfNoCachedResponseExists = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) if context.cachedResponse # we have a cached, response no need to lock anything
    log.debug "getCacheLockIfNoCachedResponseExists"
    cache.promiseToGetCacheLock(context.cacheKey)
    .then (lockDescriptor) ->
      context.cacheLockDescriptor = lockDescriptor
      resolve(context)
    .catch reject

getAndCacheResponseIfNeeded = (context) ->
  new Promise (resolve, reject) ->
    # get and cache a response for the given request, if there is already 
    # a cached response there is nothing to do
    return resolve(context) if context.cachedResponse
    log.debug "getAndCacheResponseIfNeeded"
    reject new Error("need a cacheKey inorder to cache a response, none present") if not context.cacheKey
    responseCachedHandler = (e) ->
      log.debug "responseCacheHandler for contextId #{context.contextId}"
      if e
        reject(e)
      else
        cache.tryGetCachedResponse(context.cacheKey)
        .then (cachedResponse) ->
          context.cachedResponse = cachedResponse
          resolve(context)
        .catch (e) -> reject(e)
    cache.runWhenResponseIsCached(context.cacheKey, responseCachedHandler)
    # only if we get the cache lock will we rebuild, otherwise someone else is
    # already rebuilding the cache metching this request
    if context.cacheLockDescriptor
      log.debug "we got cache lock #{context.cacheLockDescriptor} for #{context.cacheKey}, triggering rebuild"
      fauxProxyResponse = mocks.createResponse()
      handleProxyError = (e) ->
        log.error "error proxying cache rebuild request to #{context.targetConfig}\n%s", e
        reject(e)
      proxy.web(context, fauxProxyResponse, { target: context.targetConfig.target }, handleProxyError)
    else
      log.debug "didn't get the cache lock for #{context.cacheKey}, waiting for in progress rebuild contextId #{context.contextId}"


determineIfCacheIsExpired = (context) ->
  new Promise (resolve, reject) ->
    log.debug "determineIfCacheIsExpired"
    cachedResponse = context.cachedResponse
    now = new Date().getTime()
    # if our cached response is older than is configured for the max age, then we'll
    # queue up a rebuild request BUT still serve the cached response
    log.debug "create time: #{cachedResponse.createTime}, now #{now}, delta #{now - cachedResponse.createTime}, maxAge: #{context.targetConfig.maxAgeInMilliseconds}"
    context.cachedResponseIsExpired = now - cachedResponse.createTime > context.targetConfig.maxAgeInMilliseconds
    resolve(context)

getCacheLockIfCacheIsExpired = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) unless context.cachedResponseIsExpired # if it's not expired, we have nothing to do
    log.debug "getCacheLockIfCacheIsExpired"
    cache.promiseToGetCacheLock(context.cacheKey)
    .then (lockDescriptor) ->
      context.cacheLockDescriptor = lockDescriptor
      resolve(context)
    .catch reject

serveCachedResponse = (context) ->
  new Promise (resolve, reject) ->
    log.debug "serveCachedResponse"
    cachedResponse = context.cachedResponse
    cachedResponse.headers['x-cached-by-route'] = context.targetConfig.route
    cachedResponse.headers['x-cache-key'] = context.cacheKey
    cachedResponse.headers['x-cache-created'] = cachedResponse.createTime
    context.response.writeHead cachedResponse.statusCode, cachedResponse.headers
    cachedResponse.body.pipe(context.response)
    # just to follow the pattern we'll pass on the context although there's no one after us
    resolve(context)

# while this method does return a promise it doesn't actually wait for any of the results of its async
# invocations. This method simply determines if a cache rebuild should be triggered, triggers it
# accordingly.
triggerRebuildOfExpiredCachedResponse = (context) ->
  new Promise (resolve, reject) ->
    return reject new Error("no cached response found, cannot trigger rebuild") unless context.cachedResponse
    log.debug "triggerRebuildOfExpiredCachedResponse"
    cachedResponse = context.cachedResponse
    if context.cachedResponseIsExpired and context.cacheLockDescriptor
      log.debug "triggering rebuild of cache for #{context.cacheKey}"
      fauxProxyResponse = mocks.createResponse()
      handleProxyError = (e) ->
        log.error "error proxying cache rebuild request to #{context.targetConfig.target}\n%s", e
        reject(e)
      # since our resopnse is received asynchronously, via an event associated with the proxy object
      # we'll use this specific method to allow us to resolve when that takes place, so the rest of
      # the pipeline can complete normally
      context.proxiedResponseCached = () ->
        resolve(context)
      return proxy.web(context, fauxProxyResponse, { target: context.targetConfig.target }, handleProxyError)
    resolve(context)

logAndPassContext = (message) ->
  (context) ->
    new Promise (resolve) ->
      log.debug message
      resolve(context)
    

server = http.createServer (request, response) ->
  getContextThatUnlocksCacheOnDispose = () ->
    buildContext(request, response).disposer (context, promise) ->
      if context.cacheLockDescriptor
        log.debug "unlocking cache lock #{context.cacheLockDescriptor} during context dispose"
        cache.releaseCacheLock(context.cacheLockDescriptor) if context.cacheLockDescriptor
      else
        log.debug "cache not locked, no unlock needed during context dispose"

  requestPipeline = (context) ->
    Promise.resolve(context)
    .then determineIfAdminRequest
    .then determineIfProxiedOnlyOrCached
    .then handleProxyOnlyRequest
    .then readRequestBody
    .then buildCacheKey
    .then handleAdminRequest
    .then getCachedResponse
    .then getCacheLockIfNoCachedResponseExists
    .then getAndCacheResponseIfNeeded
    .then determineIfCacheIsExpired
    .then getCacheLockIfCacheIsExpired
    .then serveCachedResponse
    .then triggerRebuildOfExpiredCachedResponse
    .then logAndPassContext("request handling complete")
    .catch (e) ->
      log.debug "request handling completed in catch" if e.requestHandlingComplete
      return if e.requestHandlingComplete
      log.error "error processing request"
      log.error e.stack
      response.writeHead 500, {}
      response.end('{"status": "error", "message": "' + e.message + '"}')
  using(getContextThatUnlocksCacheOnDispose(), requestPipeline)



log.info "listening on port %s", config.listenPort
log.info "configuration: %j", config
log.debug "debug logging enabled"
server.listen(config.listenPort)
