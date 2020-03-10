// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "s3-filesystem-kit",
    platforms: [.iOS(.v12), .tvOS(.v12), .watchOS(.v5)],
    products: [
        .library(name: "S3FileSystemKit", targets: ["S3FileSystemKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-aws/aws-sdk-swift", .branch("master"))
    ],
    targets: [
        .target(name: "S3FileSystemKit", dependencies: ["AWSS3"]),
        .testTarget(name: "S3FileSystemKitTests", dependencies: ["S3FileSystemKit"]),
    ]
)
