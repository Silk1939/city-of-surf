//
//  city_of_surfTests.swift
//  city of surfTests
//
//  Created by Tan Ipekkaya on 02.08.26.
//

import XCTest
import Metal
import simd
@testable import city_of_surf

final class city_of_surfTests: XCTestCase {

    func testChaseCameraSnapsToBoardRelativeTuning() {
        var camera = ChaseCamera()
        let boardPosition = SIMD3<Float>(1, 2, 3)

        XCTAssertEqual(ChaseCameraTuning.eyeOffset, SIMD3<Float>(0, 4.5, -9.0))
        XCTAssertEqual(ChaseCameraTuning.lookTargetHeight, 2.0)

        camera.update(
            follow: boardPosition,
            steering: 0.5,
            speed: ChaseCameraTuning.baseSpeed,
            deltaTime: 1 / 60
        )

        XCTAssertEqual(
            camera.smoothEye,
            boardPosition + ChaseCameraTuning.eyeOffset
        )
        XCTAssertEqual(
            camera.smoothLookTarget,
            boardPosition + SIMD3<Float>(
                0.5 * ChaseCameraTuning.steeringLookOffset,
                ChaseCameraTuning.lookTargetHeight,
                ChaseCameraTuning.lookAheadDistance
            )
        )
        XCTAssertEqual(camera.smoothFovDegrees, ChaseCameraTuning.baseFovDegrees)
    }

    func testChaseCameraSmoothingIsFrameRateIndependent() {
        var singleStep = ChaseCamera()
        var doubleStep = ChaseCamera()
        let origin = SIMD3<Float>.zero
        let destination = SIMD3<Float>(4, 2, 8)

        singleStep.update(follow: origin, steering: 0, speed: 17, deltaTime: 0)
        doubleStep.update(follow: origin, steering: 0, speed: 17, deltaTime: 0)
        singleStep.update(follow: destination, steering: 0.8, speed: 32, deltaTime: 1 / 30)
        doubleStep.update(follow: destination, steering: 0.8, speed: 32, deltaTime: 1 / 60)
        doubleStep.update(follow: destination, steering: 0.8, speed: 32, deltaTime: 1 / 60)

        XCTAssertLessThan(simd_distance(singleStep.smoothEye, doubleStep.smoothEye), 0.0001)
        XCTAssertLessThan(
            simd_distance(singleStep.smoothLookTarget, doubleStep.smoothLookTarget),
            0.0001
        )
        XCTAssertEqual(
            singleStep.smoothFovDegrees,
            doubleStep.smoothFovDegrees,
            accuracy: 0.0001
        )
    }

    func testLightingUsesLowWarmSunCoolSkyAndExponentialFog() {
        XCTAssertGreaterThan(ArtDirection.sunDirection.y, 0)
        XCTAssertLessThan(ArtDirection.sunDirection.y, 0.35)
        XCTAssertGreaterThan(ArtDirection.sunColor.x, ArtDirection.sunColor.z)
        XCTAssertGreaterThan(
            ArtDirection.skyAmbientColor.z,
            ArtDirection.skyAmbientColor.x
        )

        let nearFog = ArtDirection.exponentialFogFactor(distance: 20)
        let farFog = ArtDirection.exponentialFogFactor(distance: 120)
        XCTAssertGreaterThan(nearFog, 0)
        XCTAssertGreaterThan(farFog, nearFog)
        XCTAssertLessThan(farFog, 1)
    }

    func testGerstnerWaveFieldHasFourLayersAndCrestFoam() {
        XCTAssertEqual(ArtDirection.Water.gerstner.count, 4)
        let wave = WaveField()
        let foam = wave.crestFoam(x: 0, z: 0, time: 0.5, scrollZ: 0)
        let n = wave.normal(x: 0, z: 0, time: 0.5, scrollZ: 0)
        XCTAssertGreaterThanOrEqual(foam, 0)
        XCTAssertLessThanOrEqual(foam, 1)
        XCTAssertEqual(simd_length(n), 1, accuracy: 0.01)
    }

    func testHDRTargetAndACESTonemapStayInDisplayRange() {
        XCTAssertEqual(RenderTargetFormat.hdrScene, .rgba16Float)
        XCTAssertEqual(RenderTargetFormat.display, .bgra8Unorm)

        let black = ArtDirection.acesTonemapped(.zero)
        let mid = ArtDirection.acesTonemapped(SIMD3<Float>(repeating: 1))
        let bright = ArtDirection.acesTonemapped(SIMD3<Float>(repeating: 16))

        XCTAssertEqual(black, .zero)
        XCTAssertGreaterThan(bright.x, mid.x)
        XCTAssertLessThanOrEqual(bright.x, 1)
        XCTAssertLessThanOrEqual(bright.y, 1)
        XCTAssertLessThanOrEqual(bright.z, 1)
    }

    func testAssetMeshKeysPreferStableFilenames() {
        XCTAssertEqual(AssetMeshKey.surfer.preferredFilenames.first, "surfer.usdz")
        XCTAssertEqual(AssetMeshKey.board.preferredFilenames.first, "board.usdz")
        XCTAssertEqual(AssetMeshKey.coin.preferredFilenames.first, "coin.usdz")
        XCTAssertTrue(AssetMeshKey.obstacleCab.preferredFilenames.contains("obstacle_cab.glb"))
    }

}
