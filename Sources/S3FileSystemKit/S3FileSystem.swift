//
// name: S3FileSystem.swift
// author: Adam Fowler
// date: 2020/03/08
import Foundation
import NIO
@_exported import S3

/// Errors returned from S3FileSystem
public enum S3FileSystemError: Error {
    case invalidAction
    case accessDenied
    case bucketDoesNotExist
    case fileDoesNotExist
    case unexpected
}

/// S3 file system object. Contains S3 access functions
public class S3FileSystem {
    
    /// Attributes that can be set at point file is written
    public struct WriteFileAttributes {
        /// Specifies what content encodings have been applied to the object
        public let contentEncoding: String?
        /// A standard MIME type describing the format of the contents
        public let contentType: String?
        /// The tag-set for the object
        public let tags: [String: String]?
        
        /// initializer
        public init(contentEncoding: String? = nil, contentType: String? = nil, tags: [String: String]? = nil) {
            self.contentEncoding = contentEncoding
            self.contentType = contentType
            self.tags = tags
        }
    }
    
    /// Attributes of file already uploaded to S3
    public struct FileAttributes {
        /// An ETag is an opaque identifier
        public let eTag: String?
        /// File size
        public let size: Int64?
        /// Last modified date of the object
        public let lastModified: Date?
        /// Specifies what content encodings have been applied to the object
        public let contentEncoding: String?
        /// A standard MIME type describing the format of the contents
        public let contentType: String?
    }
    
    /// Attributes of file returned by ListObjects
    public struct FileListAttributes {
        /// S3 file
        public let file: S3File
        /// An ETag is an opaque identifier
        public let eTag: String?
        /// File size
        public let size: Int64?
        /// Last modified date of the object
        public let lastModified: Date?
    }
    
    //MARK: Member variables
    
    /// S3 client
    let s3: S3
    /// Current folder where actions will take place
    public private(set) var currentFolder: S3Folder?
    
    //MARK: Initializer
    
    /// initializer
    /// - Parameter s3Client: s3 client to use
    public init(_ s3Client: S3) {
        self.s3 = s3Client
        self.currentFolder = nil
    }
    
    //MARK: Member functions
    
    /// Set current folder to work from. When you call this function it will verify the bucket in the path exists or create it you require that
    /// - Parameters:
    ///   - folder: S3 folder descriptor
    ///   - createBucket: Create S3 bucket if it doesnt exist
    public func setCurrentFolder(_ folder: S3Folder, createBucket: Bool = false) -> EventLoopFuture<Void> {
        let bucketFuture: EventLoopFuture<Void>
        if createBucket {
            bucketFuture = self.createBucket(bucketName: folder.bucket).map { return }
        } else {
            bucketFuture = self.headBucket(bucketName: folder.bucket).map { return }
        }
        return bucketFuture.map {
            self.currentFolder = folder
        }
    }
    
    /// Set current folder within current selected bucket
    /// - Parameter folder: folder name
    public func setCurrentFolder(_ folder: String) throws {
        guard let currentFolder = currentFolder else { throw S3FileSystemError.invalidAction }
        self.currentFolder = S3Folder(bucket: currentFolder.bucket, path: folder)
    }
    
    /// Enter subfolder relative to the current folder
    /// - Parameter folder: local folder name
    public func pushFolder(_ folder: String) throws {
        guard let folder = self.currentFolder?.subFolder(folder) else { throw S3FileSystemError.invalidAction }
        self.currentFolder = folder
    }
    
    /// Set current folder up one folder level
    public func popFolder() throws {
        guard let folder = self.currentFolder?.parent() else { throw S3FileSystemError.invalidAction }
        self.currentFolder = folder
    }
    
    /// List files in current folder
    /// - Parameter includeSubFolders: should files in subfolders be included in the list
    public func listFiles(includeSubFolders: Bool = false) -> EventLoopFuture<[FileListAttributes]> {
        guard let currentFolder = currentFolder else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return list(includeSubFolders: includeSubFolders) { response in
            guard let contents = response.contents else { return [] }
            return contents.compactMap { entry in
                guard let key = entry.key else { return nil }
                return FileListAttributes(file: S3File(bucket: currentFolder.bucket, path: key), eTag: entry.eTag, size: entry.size, lastModified: entry.lastModified?.dateValue)
            }
        }
    }
    
    /// List subfolders of current folder
    public func listSubfolders() -> EventLoopFuture<[S3Folder]> {
        guard let currentFolder = currentFolder else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return list { response in
            guard let subFolders = response.commonPrefixes else { return [] }
            return subFolders.compactMap {
                return $0.prefix != nil ? S3Folder(bucket: currentFolder.bucket, path: $0.prefix!) : nil
            }
        }
    }
    
    /// Read file into Data
    /// - Parameter name: name of file in current folder
    public func readFile(name: String) -> EventLoopFuture<Data> {
        guard let file = currentFolder?.file(name) else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return readFile(file)
    }
    
    /// Read file into Data
    /// - Parameter file: s3 file descriptor
    public func readFile(_ file: S3File) -> EventLoopFuture<Data> {
        let request = S3.GetObjectRequest(bucket: file.bucket, key: file.path)
        return s3.getObject(request)
            .flatMapThrowing { response in
                guard let body = response.body else { throw S3FileSystemError.unexpected}
                return body
            }
            .flatMapErrorThrowing { error in
                switch error {
                case S3FileSystemError.unexpected:
                    throw error
                default:
                    throw self.convertS3Errors(error)
                }
        }
    }
    
    /// Write data to file
    /// - Parameters:
    ///   - name: file name in current folder
    ///   - data: data to be written to file
    public func writeFile(name: String, data: Data, attributes: WriteFileAttributes? = nil) -> EventLoopFuture<Void> {
        guard let file = currentFolder?.file(name) else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return writeFile(file, data: data, attributes: attributes)
    }
    
    /// Write data to file
    /// - Parameters:
    ///   - file: s3 file descriptor
    ///   - data: data to be written to file
    public func writeFile(_ file: S3File, data: Data, attributes: WriteFileAttributes? = nil) -> EventLoopFuture<Void> {
        let request = S3.PutObjectRequest(
            body: data,
            bucket: file.bucket,
            contentEncoding: attributes?.contentEncoding,
            contentType: attributes?.contentType,
            key: file.path,
            tagging: attributes?.tags?.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        )
        return s3.putObject(request)
            .map { _ in return }
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }
    }
    
    /// Delete file
    /// - Parameter name: file name in current folder
    public func deleteFile(name: String) -> EventLoopFuture<Void> {
        guard let file = currentFolder?.file(name) else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return deleteFile(file)
    }
    
    /// Delete file
    /// - Parameter file: s3 file descriptor
    public func deleteFile(_ file: S3File) -> EventLoopFuture<Void> {
        let request = S3.DeleteObjectRequest(bucket: file.bucket, key: file.path)
        return s3.deleteObject(request)
            .map { _ in return }
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }

    }
    
    /// Copy file
    /// - Parameter from: source file name in current folder
    /// - Parameter to: destination file name
    public func copyFile(from: String, to: S3File) -> EventLoopFuture<Void> {
        guard let file = currentFolder?.file(from) else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return copyFile(from: file, to: to)
    }
    
    /// Copy file
    /// - Parameter from: source file name
    /// - Parameter to: destination file name
    public func copyFile(from: S3File, to: S3File) -> EventLoopFuture<Void> {
        let request = S3.CopyObjectRequest(bucket: to.bucket, copySource: "/\(from.bucket)/\(from.path)", key: to.path)
        return s3.copyObject(request)
            .map { _ in return }
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }

    }
    
    /// Get file attributes
    /// - Parameter name: file name in current folder
    public func getFileAttributes(name: String) -> EventLoopFuture<FileAttributes> {
        guard let file = currentFolder?.file(name) else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        return getFileAttributes(file)
    }
    
    /// Get file attributes
    /// - Parameter file: s3 file descriptor
    public func getFileAttributes(_ file: S3File) -> EventLoopFuture<FileAttributes> {
        let request = S3.HeadObjectRequest(bucket: file.bucket, key: file.path)
        return s3.headObject(request)
            .map { response in
                return FileAttributes(
                    eTag: response.eTag,
                    size: response.contentLength,
                    lastModified: response.lastModified?.dateValue,
                    contentEncoding: response.contentEncoding,
                    contentType: response.contentType)
            }
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }

    }

    /// Return a list of S3 buckets as S3Folders
    public func listBuckets() -> EventLoopFuture<[S3Folder]> {
        return s3.listBuckets()
            .map { buckets in
                return buckets.buckets?.compactMap { S3Folder(url: "s3://\($0)/") } ?? []
            }
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }
    }
    
    /// Return if an S3  bucket exists
    /// - Parameter bucketName: name of bucket
    public func doesBucketExist(bucketName: String) -> EventLoopFuture<Bool> {
        let request = S3.HeadBucketRequest(bucket: bucketName)
        return s3.headBucket(request)
            .map { return true }
            .flatMapErrorThrowing { error in
                return false
        }
    }
    
    /// Create an S3 bucket
    /// - Parameter bucketName: name of bucket
    public func createBucket(bucketName: String) -> EventLoopFuture<Void> {
        let request = S3.CreateBucketRequest(bucket: bucketName)
        return s3.createBucket(request)
            .map { _ in return }
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }
    }
    
    /// Delete an S3 bucket
    /// - Parameter bucketName: name of bucket
    public func deleteBucket(bucketName: String) -> EventLoopFuture<Void> {
        if currentFolder?.bucket == bucketName {
            currentFolder = nil
        }
        let request = S3.DeleteBucketRequest(bucket: bucketName)
        return s3.deleteBucket(request)
            .flatMapErrorThrowing { error in
                throw self.convertS3Errors(error)
        }
    }
    
}

/// Internal functionality
internal extension S3FileSystem {
    /// test if bucket exists, return failed EventLoopFuture is not
    func headBucket(bucketName: String) -> EventLoopFuture<Void> {
        let request = S3.HeadBucketRequest(bucket: bucketName)
        return s3.headBucket(request)
            .map { return }
            .flatMapErrorThrowing { error in
                throw S3FileSystemError.bucketDoesNotExist
        }
    }
    
    /// convert from aws-sdk-swift S3 error to s3-filesystem error
    func convertS3Errors(_ error: Error) -> Error {
        switch error {
        case S3ErrorType.noSuchBucket:
            return S3FileSystemError.bucketDoesNotExist
        case S3ErrorType.noSuchKey:
            return S3FileSystemError.fileDoesNotExist
        default:
            print("\(error)")
            return S3FileSystemError.accessDenied
        }
    }
    
    /// list objects and apply collation function to them
    func list<T>(includeSubFolders: Bool = false, _ collate: @escaping (S3.ListObjectsV2Output) -> [T]) -> EventLoopFuture<[T]> {
        guard let currentFolder = currentFolder else { return makeFailedFuture(S3FileSystemError.invalidAction) }
        let delimiter: String? = includeSubFolders ? nil : "/"
        var keys: [T] = []
        
        let request = S3.ListObjectsV2Request(bucket: currentFolder.bucket, delimiter: delimiter, prefix: currentFolder.path)
        return s3.listObjectsV2Paginator(request) { response, eventLoop in
            keys.append(contentsOf: collate(response))
            return eventLoop.makeSucceededFuture(true)
        }
        .map { return keys }
        .flatMapErrorThrowing { error in
            throw self.convertS3Errors(error)
        }
    }
    
    /// make a failed future
    func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        return s3.client.eventLoopGroup.next().makeFailedFuture(error)
    }
}

