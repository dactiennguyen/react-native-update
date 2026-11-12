export declare const readdir: (path: string) => Promise<void>;
export declare const mkdir: (path: string) => Promise<void>;
export declare const readFile: (path: string, opts?: string | {
    [key: string]: string;
}) => Promise<string | Uint8Array<ArrayBufferLike>>;
export declare const writeFile: (path: string, content: string | Uint8Array, opts?: string | {
    [key: string]: string;
}) => Promise<void>;
export declare const stat: (path: string) => Promise<void>;
export declare const lstat: (path: string) => Promise<void>;
export declare const unlink: (path: string) => Promise<void>;
export declare const rmdir: (path: string) => Promise<void>;
export declare const readlink: () => Promise<never>;
export declare const symlink: () => Promise<never>;
export declare const chmod: () => Promise<never>;
//# sourceMappingURL=fs.d.ts.map