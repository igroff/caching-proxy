Promise = require 'bluebird'
fs      = Promise.promisifyAll(require('fs'))
log     = require 'simplog'
_       = require 'lodash'
hogan   = require 'hogan.js'

config =
  listenPort: process.env.PORT || 8080
  cacheDir: process.env.CACHE_DIR || process.env.TMPDIR || process.env.TMP || '/tmp'
  lockDir: process.env.LOCK_DIR || process.env.TMPDIR || '/var/run'
  tempDir: process.env.TEMP_DIR || process.env.TMPDIR || process.env.TMP || '/tmp'
  defaultTarget: process.env.DEFAULT_TARGET || throw new Error('you must provide a default proxy target')
  targetConfigPath : process.env.TARGET_CONFIG_PATH
  requestTimeout : process.env.REQUEST_TIMEOUT || 0

if not config.targetConfigPath
  log.error "unable to start with no config specified, provide a TARGET_CONFIG_PATH"
  process.exit 1
log.info "loading target config: #{config.targetConfigPath}"
targetConfigData = fs.readFileSync(config.targetConfigPath, 'utf8')
log.info "using target config:\n%s", targetConfigData


config.setTargetConfig = (targetConfig) ->
  if typeof(targetConfig) is "string"
    targetConfigTemplate = hogan.compile(targetConfig)
    configRenderContext = process.env
    targetList = JSON.parse(targetConfigTemplate.render(configRenderContext))

  targetValidator = (target) ->
    throw new Error "target #{JSON.stringify(target)} needs a valid route value" unless target.route
    throw new Error "target #{JSON.stringify(target)} needs a valid target value" unless target.target
    throw new Error "target #{JSON.stringify(target)} must have a numeric value for maxAgeInMilliseconds" if isNaN(Number(target.maxAgeInMilliseconds))
    throw new Error "target #{JSON.stringify(target)} needs a valid maxAgeInMilliseconds value" unless target.maxAgeInMilliseconds > -1

  targetRegexBuilder = (target) ->
    if target.route is '*'
      target.regexp = new RegExp(/./)
    else
      target.regexp = new RegExp('^' + target.route.replace(/\//g, '\\/'))

  throw new Error "target config must be an array of target configuration objects" unless _.isArray targetList
  targetList.forEach(targetValidator)
  targetList.forEach(targetRegexBuilder)
  config.targets = targetList

config.findMatchingTarget = (url) ->
  # find the config that matches this request
  matchedTarget =  _.find(config.targets, (target) -> target.regexp.test(url))
  # if there is no matching target, then we'll create a cacheless target for the
  # default target, this means that the default behavior of the proxy is to
  # proxy to the default target with no caching
  if not matchedTarget
    matchedTarget =
      maxAgeInMilliseconds: 0
      target: config.defaultTarget
      route: "default"
  log.debug "target #{matchedTarget.route} matched url: #{url}"
  return matchedTarget

config.saveTargetConfig = () ->
  targetConfig = _.cloneDeep config.targets
  _.each targetConfig, (target) -> delete(target['regexp'])
  fs.writeFileAsync(config.targetConfigPath, JSON.stringify(targetConfig, null, 2), {flag: 'w+'})

config.setTargetConfig(targetConfigData)
module.exports = config
