import type { DownloadManager } from './download';
import type { UpdateGitOption, UpdateOption, BundleInfo } from './type';
declare function setupBundlePath(path: string, extension?: string, version?: number, maxVersions?: number, metadata?: any): Promise<boolean>;
declare function setupExactBundlePath(path: string): Promise<boolean>;
type Metadata = object | number | string | boolean | null;
declare function getUpdateMetadata<T extends Metadata = Metadata>(): Promise<T>;
declare function rollbackToPreviousBundle(): Promise<boolean>;
declare function getVersionAsNumber(): Promise<number>;
declare function setCurrentVersion(version: number): Promise<boolean>;
declare function setUpdateMetadata<T extends Metadata = Metadata>(metadata: T): Promise<boolean>;
declare function resetApp(): Promise<void>;
declare function removeBundle(restartAfterRemoved?: boolean): void;
declare function downloadBundleUri(downloadManager: DownloadManager, uri: string, version?: number, option?: UpdateOption): Promise<void>;
declare function getBundleList(): Promise<BundleInfo[]>;
declare function deleteBundleById(id: string): Promise<boolean>;
declare function clearAllBundles(): Promise<boolean>;
declare const _default: {
    setupBundlePath: typeof setupBundlePath;
    setupExactBundlePath: typeof setupExactBundlePath;
    removeUpdate: typeof removeBundle;
    downloadBundleUri: typeof downloadBundleUri;
    resetApp: typeof resetApp;
    getCurrentVersion: typeof getVersionAsNumber;
    setCurrentVersion: typeof setCurrentVersion;
    getUpdateMetadata: typeof getUpdateMetadata;
    setUpdateMetadata: typeof setUpdateMetadata;
    rollbackToPreviousBundle: typeof rollbackToPreviousBundle;
    getBundleList: typeof getBundleList;
    deleteBundleById: typeof deleteBundleById;
    clearAllBundles: typeof clearAllBundles;
    git: {
        removeGitUpdate: (folder?: string) => void;
        cloneRepo: (options: import("./type").CloneOption) => Promise<{
            success: boolean;
            msg: null;
            bundle: string;
        } | {
            success: boolean;
            msg: any;
            bundle: null;
        }>;
        pullUpdate: (options: import("./type").PullOption) => Promise<{
            success: boolean;
            msg: any;
        }>;
        getBranchName: (folderName?: string) => Promise<any>;
        setConfig: (folderName?: string, options?: {
            userName?: string;
            email?: string;
        }) => Promise<void>;
        getConfig: (folderName?: string) => Promise<any>;
        checkForGitUpdate: (options: UpdateGitOption) => Promise<void>;
    };
};
export default _default;
//# sourceMappingURL=index.d.ts.map