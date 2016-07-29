crypto  = require 'crypto'
_       = require 'lodash'
log     = require 'simplog'

config  = require '../config.coffee'

buildRequestInfoFor = (req) ->
  # we're going to pick off the information that we require to do the
  # proxying and caching that we provide as a service
  requestInfo =
    url: req.url
    queryString: req.url.split('?')[1]
    method: req.method
    headers: req.headers
  requestInfo.config = config.findMatchingTarget(requestInfo.url)
  # build a cache key
  cacheKeyData = "#{JSON.stringify(_.extend({}, requestInfo.url))}"
  requestInfo.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
  return requestInfo

module.exports.buildRequestInfoFor = buildRequestInfoFor
