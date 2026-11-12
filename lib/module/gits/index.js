"use strict";

import './helper/fileReader.js';

// @ts-ignore
import * as promises from "./helper/fs.js";
let git, http;
try {
  git = require('isomorphic-git/index.umd.min.js');
  http = require('isomorphic-git/http/web/index.js');
} catch (err) {
  console.warn('isomorphic-git not found, running without Git support.', err);
  git = {};
  http = {};
}
const fs = {
  promises
};
const getFolder = folderName => {
  try {
    const {
      DocumentDirectoryPath
    } = require('react-native-fs');
    return DocumentDirectoryPath + (folderName || '/app_core');
  } catch (e) {}
  return '';
};
/**
 * Should set config after clone success, otherwise cannot pull
 */
const setConfig = async (folderName, options) => {
  await git.setConfig({
    fs,
    dir: getFolder(folderName),
    path: options?.userName || 'user.name',
    value: options?.email || 'appcore'
  });
};
const cloneRepo = async options => {
  try {
    await git.clone({
      fs,
      http,
      dir: getFolder(options?.folderName),
      url: options?.url,
      singleBranch: true,
      depth: 1,
      ref: options?.branch,
      onProgress({
        loaded,
        total
      }) {
        if (options?.onProgress && total > 0) {
          options?.onProgress(loaded, total);
        }
      }
    });
    return {
      success: true,
      msg: null,
      bundle: `${getFolder(options?.folderName)}/${options.bundlePath}`
    };
  } catch (e) {
    return {
      success: false,
      msg: e.toString(),
      bundle: null
    };
  } finally {
    setConfig(options?.folderName, {
      email: options?.email,
      userName: options?.userName
    });
  }
};
const pullUpdate = async options => {
  try {
    let count = 0;
    await git.pull({
      fs,
      http,
      dir: getFolder(options?.folderName),
      ref: options?.branch,
      singleBranch: true,
      onProgress({
        loaded,
        total
      }) {
        if (total > 0) {
          count = total;
          if (options?.onProgress) {
            options?.onProgress(loaded, total);
          }
        }
      }
    });
    return {
      success: count > 0,
      msg: count > 0 ? 'Pull success' : 'No updated'
    };
  } catch (e) {
    console.log(e.toString());
    return {
      success: false,
      msg: e.toString()
    };
  }
};
const getBranchName = async folderName => {
  try {
    return await git.currentBranch({
      fs,
      dir: getFolder(folderName),
      fullname: false
    });
  } catch (e) {
    console.log(e.toString());
    return null;
  }
};
const getConfig = async folderName => {
  try {
    return await git.getConfig({
      fs,
      dir: getFolder(folderName),
      path: 'remote.origin.url'
    });
  } catch (e) {
    console.log(e.toString());
    return null;
  }
};
const removeGitUpdate = folderName => {
  fs.promises.unlink(getFolder(folderName));
};
export default {
  cloneRepo,
  pullUpdate,
  getBranchName,
  setConfig,
  removeGitUpdate,
  getConfig
};
//# sourceMappingURL=index.js.map