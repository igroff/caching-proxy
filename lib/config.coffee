Promise = require 'bluebird'
fs      = Promise.promisifyAll(require('fs'))
log     = require 'simplog'
_       = require 'lodash'

config =
  listenPort: process.env.PORT || 8080
  cacheDir: process.env.CACHE_DIR || process.env.TMPDIR || process.env.TMP || '/tmp'
  lockDir: process.env.LOCK_DIR || process.env.LOCK_DIR || '/var/run'
  tempDir: process.env.TEMP_DIR || process.env.TMPDIR || process.env.TMP || '/tmp'
  defaultTarget: process.env.DEFAULT_TARGET || throw new Error('you must provide a default proxy target')
  targetConfigPath : process.env.TARGET_CONFIG_PATH

if not config.targetConfigPath
  log.error "unable to start with no config specified, provide a TARGET_CONFIG_PATH"
  process.exit 1
log.info "loading target config: #{config.targetConfigPath}"
targetConfigData = fs.readFileSync(config.targetConfigPath, 'utf8')
log.info "using target config:\n%s", targetConfigData

config.targets = JSON.parse(targetConfigData)

targetRegexBuilder = (target) ->
  if target.route is '*'
    target.regexp = new RegExp(/./)
  else
    target.regexp = new RegExp('^' + target.route.replace(/\//g, '\\/'))

config.targets.forEach(targetRegexBuilder)

config.findMatchingTarget = (url) ->
  # find the config that matches this request
  matchedTarget =  _.clone(_.find(config.targets, (target) -> target.regexp.test(url)))
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

module.exports = config
