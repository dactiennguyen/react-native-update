"use strict";

import { Buffer } from 'buffer';
let RNFS = {
  unlink: console.log,
  readdir: console.log,
  mkdir: console.log,
  readFile: console.log,
  writeFile: console.log,
  stat: console.log
};
try {
  RNFS = require('react-native-fs');
} catch {}

// Try to load native AppCore module for better performance
let AppCoreNative = null;
try {
  const {
    NativeModules
  } = require('react-native');
  AppCoreNative = NativeModules.AppCore;
} catch (e) {
  // Native module not available, will fallback to RNFS
}
function Err(name) {
  return class extends Error {
    code = name;
    constructor(...args) {
      super(...args);
      if (this.message) {
        this.message = name + ': ' + this.message;
      } else {
        this.message = name;
      }
    }
  };
}

// const EEXIST = Err('EEXIST'); // <-- Unused because RNFS's mkdir never throws
const ENOENT = Err('ENOENT');
const ENOTDIR = Err('ENOTDIR');
// const ENOTEMPTY = Err('ENOTEMPTY'); // <-- Unused because RNFS's unlink is recursive by default

export const readdir = async path => {
  try {
    return await RNFS.readdir(path);
  } catch (err) {
    switch (err.message) {
      case 'Attempt to get length of null array':
        {
          throw new ENOTDIR(path);
        }
      case 'Folder does not exist':
        {
          throw new ENOENT(path);
        }
      default:
        throw err;
    }
  }
};
export const mkdir = async path => {
  return RNFS.mkdir(path);
};
export const readFile = async (path, opts) => {
  let encoding;
  if (typeof opts === 'string') {
    encoding = opts;
  } else if (typeof opts === 'object') {
    encoding = opts.encoding;
  }

  // @ts-ignore
  let result = await RNFS.readFile(path, encoding || 'base64');
  if (!encoding) {
    // @ts-ignore
    result = Buffer.from(result, 'base64');
  }
  return result;
};
export const writeFile = async (path, content, opts) => {
  let encoding;
  if (typeof opts === 'string') {
    encoding = opts;
  } else if (typeof opts === 'object') {
    encoding = opts.encoding;
  }
  if (typeof content === 'string') {
    // Text file - use RNFS (fast enough for text)
    encoding = encoding || 'utf8';
    await RNFS.writeFile(path, content, encoding);
  } else {
    // Binary file - try native module first for better performance
    encoding = 'base64';
    const base64Content = Buffer.from(content).toString('base64');
    if (AppCoreNative && AppCoreNative.writeFile) {
      try {
        // Use native write (runs on native thread, doesn't block JS thread)
        await AppCoreNative.writeFile(path, base64Content, encoding);
      } catch (e) {
        // Fallback to RNFS if native fails
        console.warn('AppCore.writeFile failed, falling back to RNFS:', e);
        await RNFS.writeFile(path, base64Content, encoding);
      }
    } else {
      // No native module available - use RNFS
      await RNFS.writeFile(path, base64Content, encoding);
    }
  }
};
export const stat = async path => {
  try {
    const r = await RNFS.stat(path);
    // we monkeypatch the result with a `isSymbolicLink` method because isomorphic-git needs it.
    // Since RNFS doesn't appear to support symlinks at all, we'll just always return false.
    // @ts-ignore
    r.isSymbolicLink = () => false;
    return r;
  } catch (err) {
    switch (err.message) {
      case 'File does not exist':
        {
          throw new ENOENT(path);
        }
      default:
        throw err;
    }
  }
};

// Since there are no symbolic links, lstat and stat are equivalent
export const lstat = stat;
export const unlink = async path => {
  try {
    await RNFS.unlink(path);
  } catch (err) {
    switch (err.message) {
      case 'File does not exist':
        {
          throw new ENOENT(path);
        }
      default:
        throw err;
    }
  }
};

// RNFS doesn't have a separate rmdir method, so we can use unlink for deleting directories too
export const rmdir = unlink;

// These are optional, which is good because there is no equivalent in RNFS
export const readlink = async () => {
  throw new Error('not implemented');
};
export const symlink = async () => {
  throw new Error('not implemented');
};

// Technically we could pull this off by using `readFile` + `writeFile` with the `mode` option
// However, it's optional, because isomorphic-git will do exactly that (a readFile and a writeFile with the new mode)
export const chmod = async () => {
  throw new Error('not implemented');
};
//# sourceMappingURL=fs.js.map