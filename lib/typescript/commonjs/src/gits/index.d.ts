import './helper/fileReader.js';
import type { CloneOption, PullOption } from '../type';
declare const _default: {
    cloneRepo: (options: CloneOption) => Promise<{
        success: boolean;
        msg: null;
        bundle: string;
    } | {
        success: boolean;
        msg: any;
        bundle: null;
    }>;
    pullUpdate: (options: PullOption) => Promise<{
        success: boolean;
        msg: any;
    }>;
    getBranchName: (folderName?: string) => Promise<any>;
    setConfig: (folderName?: string, options?: {
        userName?: string;
        email?: string;
    }) => Promise<void>;
    removeGitUpdate: (folderName?: string) => void;
    getConfig: (folderName?: string) => Promise<any>;
};
export default _default;
//# sourceMappingURL=index.d.ts.map