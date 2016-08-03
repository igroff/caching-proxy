#! /usr/bin/env node_modules/.bin/coffee
Promise       = require 'bluebird'
http          = require 'http'
httpProxy     = require 'http-proxy'
EventEmitter  = require 'events'
log           = require 'simplog'
mocks         = require 'node-mocks-http'

lock      = require './lib/file_lock.coffee'
config    = require './lib/config.coffee'
cache     = require './lib/cache.coffee'
utils     = require './lib/util'
admin     = require './lib/admin_handlers.coffee'
 
proxy = httpProxy.createProxyServer({})

# this event is raised when we get a response from the proxied service
# it is here that we will cache responses, while it'd be awesome to do this
# another way this is currently the only way to get the response from
# http-proxy
proxy.on 'proxyRes', (proxyRes, request, res) ->
  # a configuration may specify that the response be cached, or simply proxied.
  # In the case of caching being desired a cacheKey will be present otherwise
  # there will be no cacheKey.  So, if no cache key, no caching has been requested
  if request.__cacheKey
    cache.cacheResponse(request.__cacheKey, proxyRes)
    .then( -> cache.releaseCacheLock(request.__cacheKey))

# this method actually proxies through the request as configured, returning
# a promise which is resolved when the response from the service is complete
# or an error is encountered
rebuildResponseCache = (requestInfo) ->
  completeProxyRequest = new Promise (resolve, reject) ->
    fauxProxyResponse = mocks.createResponse()
    handleProxyError = (e) ->
      if requestInfo.cacheKey
        cache.releaseCacheLock(requestInfo.cacheKey)
      log.error "error proxying cache rebuild request to #{requestInfo.config.target}\n%s", e
      reject(e)
    responseCachedHandler = (e) ->
      if e
        reject(e)
      else
        resolve()
    cache.runWhenResponseIsCached(requestInfo.cacheKey, responseCachedHandler)
    proxy.web(requestInfo.request, fauxProxyResponse, { target: requestInfo.config.target }, handleProxyError)

# retrieves a response for a given request, in this case it either fetches one from the
# cache or reubuilds the cache and then returns what has been cached
getCachedResponse = (requestInfo) ->
  # return a response from our cache or queue up a request
  # and wait for the response, then return it
  cache.tryGetCachedResponse(requestInfo.cacheKey)
  .then (cachedResponse) ->
    if cachedResponse
      Promise.resolve(cachedResponse)
    else
      log.debug "proxying request to #{requestInfo.config.target}"
      rebuildResponseCache(requestInfo)
      .then( () -> cache.tryGetCachedResponse(requestInfo.cacheKey) )

rebuildCacheAsNeeded = (requestInfo, cachedResponse) ->
  now = new Date().getTime()
  # if our cached response is older than is configured for the max age, then we'll
  # queue up a rebuild request BUT still serve the cached response
  log.debug "create time: #{cachedResponse.createTime}, now #{now}, delta #{now - cachedResponse.createTime}, maxAge: #{requestInfo.config.maxAgeInMilliseconds}"
  if now - cachedResponse.createTime > requestInfo.config.maxAgeInMilliseconds
    # only trigger the rebuild if we can get the cache lock, if we cannot get it
    # someone else is rebuilding this already
    if cache.getCacheLock requestInfo.cacheKey
      log.debug "triggering rebuild of cache for #{requestInfo.cacheKey}"
      rebuildResponseCache(requestInfo)
  
server = http.createServer (request, res) ->
  admin.decorateAdminRequest(request)
  utils.buildRequestInfoFor(request)
  .then (requestInfo) ->
    if admin.isAdminRequest(requestInfo.request)
      admin.requestHandler(requestInfo, res)
    else if requestInfo.cacheKey
      # if we have a cache key, then we're are handling a cacheable request
      getCachedResponse(requestInfo)
      .then (cachedResponse) ->
        rebuildCacheAsNeeded(requestInfo, cachedResponse)
        cachedResponse.headers['x-cached-by-route'] = requestInfo.config.route
        cachedResponse.headers['x-cache-key'] = requestInfo.cacheKey
        cachedResponse.headers['x-cache-created'] = cachedResponse.createTime
        res.writeHead cachedResponse.statusCode, cachedResponse.headers
        cachedResponse.body.pipe(res)
      .catch (e) ->
        log.error "failed to handle request #{requestInfo}"
        log.error e
        res.writeHead 500, {}
        res.end('{"status": "error", "message": "' + e.message + '"}')
    else
      # no cache key means we'll just be proxying 
      log.debug "proxy only request for #{requestInfo.url}"
      proxyError = (e) ->
        log.error "error during proxy only request #{requestInfo}"
        log.error e
        res.writeHead 500, {}
        res.end('{"status": "error", "message": "' + e.message + '"}')
      proxy.web(request, res, { target: requestInfo.config.target }, proxyError)

log.info "listening on port %s", config.listenPort
log.info "configuration: %j", config
log.debug "debug logging enabled"
server.listen(config.listenPort)
