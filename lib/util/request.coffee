Promise = require 'bluebird'
crypto  = require 'crypto'
_       = require 'lodash'
log     = require 'simplog'

config  = require '../config.coffee'

# This class extends readable because it's going to be a fake request for our proxy
# this is necessary because we're going to consume our inbound request (stream) so that
# we can get the request body, as it's part of what defines a unique request and thus a cache
# key.  So when we ultimately proxy a request on to the backend, we will use this object
class RequestInfo extends require('stream').Readable
  constructor: (req) ->
      @url = req.url
      @queryString = req.url.split('?')[1]
      @method = req.method
      @headers = req.headers
      @rawHeaders = req.rawHeaders
      @httpVersion = req.httpVersion
      @body = ""
      @request = req
      @socket = req.socket
      super({})
  toString: => JSON.stringify(url: @url, method: @method, config: @config, body: @body)
  _read: (size) =>
    @.push(this.body)
    @.push(null)


buildRequestInfoFor = (req) ->
  new Promise (resolve, reject) ->
    # we're going to pick off the information that we require to do the
    # proxying and caching that we provide as a service
    requestInfo = new RequestInfo(req)

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
        cacheKeyData = "#{requestInfo.method}-#{requestInfo.url}-#{requestInfo.body}"
        requestInfo.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
        requestInfo.__cacheKey = requestInfo.cacheKey
    # gather all our request data as it becomes available, in practice we expect this 'data' event to
    # only be raised once with the full content of the request
    req.on 'data', (data) -> requestInfo.body += data
    req.on 'end', () ->
      processRequestInfo(requestInfo)
      log.info "#{requestInfo}"
      resolve(requestInfo)
    req.on 'error', reject

module.exports.buildRequestInfoFor = buildRequestInfoFor
