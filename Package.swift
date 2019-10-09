// swift-tools-version:4.0
import PackageDescription

let productName = "Kumo"

let package = Package(
    name: productName,
    products: [
        .library(name: productName, targets: [productName])
    ],
    dependencies: [
        .package(url: "https://github.com/reactivex/rxswift.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: productName,
            dependencies: ["RxSwift"]
        ),
        .testTarget(
            "name": "\(productName)Tests",
            dependencies: [productName, "RxSwift"]
        )
    ]
)