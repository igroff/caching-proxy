Promise = require 'bluebird'
crypto  = require 'crypto'
_       = require 'lodash'
log     = require 'simplog'

config  = require '../config.coffee'

buildRequestInfoFor = (req, url=undefined) ->
  new Promise (resolve, reject) ->
    # we're going to pick off the information that we require to do the
    # proxying and caching that we provide as a service
    #
    # we allow the url to be passed in (optionally) because we have some cases
    # of 'special' URLs used to access proxy functionality by prepending informaiton
    # to an otherwise standard ( would be proxied ) URL
    requestInfo =
      url: url or req.url
      queryString: req.url.split('?')[1]
      method: req.method
      headers: req.headers
      body: ""
      request: req
      toString: () -> JSON.stringify(_.omit(this, 'request'))
    processRequestInfo = (requestInfo) ->
      # it's prossible to specify a proxy target in the request, this is intended to 
      # be used for testing configuration changes prior to setting them 'in stone' via
      # the config file, if the header is not present or an error is encountered while
      # parsing it, we'll go ahead an pick as normal
      if requestInfo.headers['x-proxy-target-config']
        try
          requestInfo.config = JSON.parse(requestInfo.headers['x-proxy-target-config'])
        catch e
          log.error "error processing proxy target from request header"
          log.error e
     
      # if we still don't have a target config, we'll find one as normal
      if not requestInfo.config
        requestInfo.config = config.findMatchingTarget(requestInfo.url)

      # if we have no max age for the cache, then there will be no caching 
      # for this request, thus no need for a cache key
      if requestInfo.config.maxAgeInMilliseconds > 0
        # build a cache key
        cacheKeyData = "#{requestInfo.method}-#{requestInfo.url}"
        requestInfo.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
        requestInfo.request.__cacheKey = requestInfo.cacheKey
    # gather all our request data as it becomes available, in practice we expect this 'data' event to
    # only be raised once with the full content of the request
    req.on 'data', (data) -> req.body += data
    req.on 'end', () ->
      processRequestInfo(requestInfo)
      log.info "#{requestInfo}"
      resolve(requestInfo)
    req.on 'error', reject

module.exports.buildRequestInfoFor = buildRequestInfoFor
