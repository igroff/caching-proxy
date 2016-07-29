crypto  = require 'crypto'
_       = require 'lodash'
log     = require 'simplog'

config  = require '../config.coffee'

buildRequestInfoFor = (req, url=undefined) ->
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
  requestInfo.config = config.findMatchingTarget(requestInfo.url)
  # if we have no max age for the cache, then there will be no caching 
  # for this request, thus no need for a cache key
  if requestInfo.config.maxAgeInMilliseconds > 0
    # build a cache key
    cacheKeyData = "#{JSON.stringify(_.extend({}, requestInfo.url))}"
    requestInfo.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
  return requestInfo

module.exports.buildRequestInfoFor = buildRequestInfoFor
