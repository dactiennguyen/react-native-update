"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.default = void 0;
var _reactNative = require("react-native");
var _index = _interopRequireDefault(require("./gits/index.js"));
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
const LINKING_ERROR = `The package 'react-native-app-core' doesn't seem to be linked. Make sure: \n\n` + _reactNative.Platform.select({
  ios: "- You have run 'pod install'\n",
  default: ''
}) + '- You rebuilt the app after installing the package\n' + '- You are not using Expo Go\n';

// @ts-expect-error
const isTurboModuleEnabled = global.__turboModuleProxy != null;
const AppCoreModule = isTurboModuleEnabled ? require('./NativeAppCore').default : _reactNative.NativeModules.AppCore;
const RNAppCore = AppCoreModule ? AppCoreModule : new Proxy({}, {
  get() {
    throw new Error(LINKING_ERROR);
  }
});
const downloadBundleFile = async (downloadManager, uri, headers, callback) => {
  const res = await downloadManager.config({
    fileCache: _reactNative.Platform.OS === 'android',
    path: !!downloadManager?.fs?.dirs?.LibraryDir && _reactNative.Platform.OS === 'ios' ? `${downloadManager.fs.dirs.LibraryDir}/${new Date().valueOf()}_appcore.zip` : undefined
  }).fetch('GET', uri, {
    ...headers
  }).progress((received, total) => {
    if (callback) {
      callback(received, total);
    }
  });
  return res.path();
};
function setupBundlePath(path, extension, version, maxVersions, metadata) {
  const metadataString = metadata ? JSON.stringify(metadata) : undefined;
  return RNAppCore.setupBundlePath(path, extension, version, maxVersions || 2, metadataString);
}
function setupExactBundlePath(path) {
  return RNAppCore.setExactBundlePath(path);
}
function deleteBundlePath() {
  return RNAppCore.deleteBundle(1);
}
function getCurrentVersion() {
  return RNAppCore.getCurrentVersion(0);
}
function getUpdateMetadata() {
  return RNAppCore.getUpdateMetadata(0).then(metadataString => {
    try {
      return metadataString ? JSON.parse(metadataString) : null;
    } catch (error) {
      return Promise.reject(new Error('Error parsing metadata'));
    }
  });
}
function rollbackToPreviousBundle() {
  return RNAppCore.rollbackToPreviousBundle(0);
}
async function getVersionAsNumber() {
  const rawVersion = await getCurrentVersion();
  return +rawVersion;
}
function setCurrentVersion(version) {
  return RNAppCore.setCurrentVersion(version + '');
}
function setUpdateMetadata(metadata) {
  try {
    const metadataString = JSON.stringify(metadata);
    return RNAppCore.setUpdateMetadata(metadataString);
  } catch (error) {
    return Promise.reject(new Error('Failed to stringify metadata'));
  }
}
async function resetApp() {
  RNAppCore.restart();
}
function removeBundle(restartAfterRemoved) {
  deleteBundlePath().then(data => {
    if (data && restartAfterRemoved) {
      setTimeout(() => {
        resetApp();
      }, 300);
      if (data) {
        setCurrentVersion(0);
      }
    }
  });
}
/**
 * Turn anything thrown into a readable message.
 * JSON.stringify(new Error(...)) returns "{}" because message/stack are not
 * enumerable, which used to hide the real reason of every failure.
 */
const serializeError = e => {
  if (e == null) {
    return 'Unknown error';
  }
  if (typeof e === 'string') {
    return e;
  }
  if (e instanceof Error) {
    const message = e.message || e.name || 'Unknown error';
    return typeof __DEV__ !== 'undefined' && __DEV__ && e.stack ? `${message}\n${e.stack}` : message;
  }
  if (typeof e === 'object') {
    if (typeof e.message === 'string' && e.message) {
      return e.message;
    }
    try {
      const json = JSON.stringify(e);
      if (json && json !== '{}') {
        return json;
      }
    } catch (_) {
      // circular or non-serializable, fall through
    }
    return String(e);
  }
  return String(e);
};
const installFail = (option, e) => {
  const message = serializeError(e);
  option?.updateFail?.(message);
  console.error('Download bundle fail', message);
};
async function downloadBundleUri(downloadManager, uri, version, option) {
  if (!uri) {
    return installFail(option, 'Please give a valid URL!');
  }
  if (version) {
    if (typeof version !== 'number' || !Number.isFinite(version)) {
      return installFail(option, `Version must be a number, received: ${JSON.stringify(version)} (${typeof version}). ` + 'Use a numeric build number instead of a semver string, e.g. 1, 2, 3.');
    }
    const currentVersion = await getVersionAsNumber();
    if (version <= currentVersion) {
      return installFail(option, 'Please give a bigger version than the current version, the current version now has setted by: ' + currentVersion);
    }
  }
  try {
    const path = await downloadBundleFile(downloadManager, uri, option?.headers, option?.progress);
    if (!path) {
      return installFail(option, `Cannot download bundle file: ${path}`);
    }
    const success = await setupBundlePath(path, option?.extensionBundle, version, option?.maxBundleVersions, option?.metadata);
    if (!success) {
      return installFail(option, `Cannot setup bundle path: ${path}. The downloaded file may be corrupted or is not a valid bundle.`);
    }
    if (version) {
      setCurrentVersion(version);
    }
    if (option?.metadata) {
      setUpdateMetadata(option.metadata);
    }
    option?.updateSuccess?.();
    if (option?.restartAfterInstall) {
      setTimeout(() => {
        resetApp();
      }, option?.restartDelay || 300);
    }
  } catch (e) {
    installFail(option, e);
  }
}
const checkForGitUpdate = async options => {
  try {
    if (!options.url || !options.bundlePath) {
      throw new Error(`url or bundlePath should not be null`);
    }
    const [config, branch] = await Promise.all([_index.default.getConfig(), _index.default.getBranchName()]);
    if (branch && config) {
      const pull = await _index.default.pullUpdate({
        branch,
        onProgress: options?.onProgress,
        folderName: options?.folderName
      });
      if (pull.success) {
        options?.onPullSuccess?.();
        if (options?.restartAfterInstall) {
          setTimeout(() => {
            resetApp();
          }, 300);
        }
      } else {
        options?.onPullFailed?.(pull.msg);
      }
    } else {
      const clone = await _index.default.cloneRepo({
        onProgress: options?.onProgress,
        folderName: options?.folderName,
        url: options.url,
        branch: options?.branch,
        bundlePath: options.bundlePath
      });
      if (clone.success && clone.bundle) {
        await setupExactBundlePath(clone.bundle);
        options?.onCloneSuccess?.();
        if (options?.restartAfterInstall) {
          setTimeout(() => {
            resetApp();
          }, 300);
        }
      } else {
        options?.onCloneFailed?.(clone.msg);
      }
    }
  } catch (e) {
    options?.onCloneFailed?.(e.toString());
  } finally {
    options?.onFinishProgress?.();
  }
};
/**
 * Metadata is stored as a JSON string, and each platform decodes it differently:
 * Android (JSONObject) only restores plain objects, iOS (NSJSONSerialization)
 * restores objects and arrays. Anything else comes back as the raw JSON string,
 * so decode it here to keep the value identical to what was passed in.
 */
const parseBundleMetadata = metadata => {
  if (typeof metadata !== 'string') {
    return metadata;
  }
  try {
    return JSON.parse(metadata);
  } catch (e) {
    // Not JSON (e.g. written by an older version) - keep the raw value.
    return metadata;
  }
};
function getBundleList() {
  return RNAppCore.getBundleList(0).then(jsonString => {
    try {
      const data = JSON.parse(jsonString);
      return data.map(item => ({
        ...item,
        date: new Date(item.date),
        metadata: parseBundleMetadata(item.metadata)
      }));
    } catch (error) {
      return Promise.reject(new Error('Error parsing bundle list'));
    }
  });
}
function deleteBundleById(id) {
  return RNAppCore.deleteBundleById(id);
}
function clearAllBundles() {
  return RNAppCore.clearAllBundles(0);
}
var _default = exports.default = {
  setupBundlePath,
  setupExactBundlePath,
  removeUpdate: removeBundle,
  downloadBundleUri,
  resetApp,
  getCurrentVersion: getVersionAsNumber,
  setCurrentVersion,
  getUpdateMetadata,
  setUpdateMetadata,
  rollbackToPreviousBundle,
  getBundleList,
  deleteBundleById,
  clearAllBundles,
  git: {
    checkForGitUpdate,
    ..._index.default,
    removeGitUpdate: folder => {
      RNAppCore.setExactBundlePath('');
      _index.default.removeGitUpdate(folder);
    }
  }
};
//# sourceMappingURL=index.js.map