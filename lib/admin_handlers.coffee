log       = require 'simplog'
config    = require './config.coffee'
utils     = require './util'

handleAdminRequest = (request, res) ->
  trimmedUrl = request.url.replace(/^\/\/\/\//, '')
  log.debug "handling non proxied request url #{trimmedUrl}"
  parts = trimmedUrl.split '/'
  command = parts.shift()
  trimmedUrl = parts.join('/')
  requestInfo = utils.buildRequestInfoFor(request, trimmedUrl)
  if requestInfo.method is "DELETE"
    return handleDeleteRequest(requestInfo, res)
  else if command is 'delete'
    return handleDeleteRequest(requestInfo, res)
  else if command is "config"
    # just handing back the current config for whatever reason the caller
    # may have need of seeing it
    res.end(JSON.stringify({status: 'ok', config: config}))
  else if command is "target"
    # return the target config that matches the request
    targetConfig = config.findMatchingTarget(requestInfo.url)
    res.end(JSON.stringify(targetConfig))
  else if command is 'saveTargetConfig'
    handleConfigSaveRequest(requestInfo, res)
  else
    res.end(JSON.stringify(status: 'error', message: 'unknown request'))

# this handles a request to save our config, since it can be modified at runtime
# we may want to ( or not want to ) persist any changes to disk so we allow the
# user to decide by invoking this method
handleConfigSaveRequest = (requestInfo, res) ->
  config.saveTargetConfig()
  .then () -> res.end(JSON.stringify(status: 'ok'))
  .catch (e) ->
    log.error "error saving target configuration data\n%s", e
    res.end(JSON.stringify(status: 'error', message: e.message))

# this handles a request to delete a cache entry
handleDeleteRequest = (requestInfo, res) ->
  cache.deleteCacheEntry(requestInfo.cacheKey)
  .then () ->
    res.end(JSON.stringify(status: 'ok', message: 'cache entry removed'))
  .catch (e) ->
    log.error "error removing cache entry\n%s", e
    res.end(JSON.stringify(status: 'error', message: e.message))

module.exports.requestHandler = handleAdminRequest
