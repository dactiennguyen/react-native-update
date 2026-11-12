import type { TurboModule } from 'react-native';
export interface Spec extends TurboModule {
    setupBundlePath(path: string, extension: string, version?: number, maxVersions?: number, metadata?: string): Promise<boolean>;
    setExactBundlePath(path: string): Promise<boolean>;
    deleteBundle(i: number): Promise<boolean>;
    restart(): void;
    getCurrentVersion(a: number): Promise<string>;
    getUpdateMetadata(a: number): Promise<string>;
    setCurrentVersion(version: string): Promise<boolean>;
    setUpdateMetadata(metadata: string): Promise<boolean>;
    rollbackToPreviousBundle(a: number): Promise<boolean>;
    getBundleList(a: number): Promise<string>;
    deleteBundleById(id: string): Promise<boolean>;
    clearAllBundles(a: number): Promise<boolean>;
    writeFile(path: string, base64Content: string, encoding: string): Promise<boolean>;
}
declare const _default: Spec;
export default _default;
//# sourceMappingURL=NativeAppCore.d.ts.map