// Commits one 64x64 piece of Metal work per argument and prints the process's physical
// footprint after each, to show what the driver charges for each kind of encoder.
//   render   an empty render pass that clears a private texture
//   blit     a buffer-to-texture blit into a private texture
//   compute  a one-threadgroup compute dispatch
//   replace  replaceRegion into a shared texture (CPU only, no command encoder)
//   idle     sleep 2 s with no GPU work
import Foundation
import Metal

func footprint() -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return String(format: "%.0f MB", Double(info.phys_footprint) / 1e6)
}

let size = 64
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try! device.makeLibrary(source: """
    kernel void k(device float* b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = i; }
    """, options: nil)
func texture(_ storage: MTLStorageMode, _ usage: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
    d.storageMode = storage
    d.usage = usage
    return device.makeTexture(descriptor: d)!
}
print("start", footprint())

for step in CommandLine.arguments.dropFirst() {
    if step == "idle" {
        Thread.sleep(forTimeInterval: 2)
        print(step, footprint())
        continue
    }
    let cb = queue.makeCommandBuffer()!
    switch step {
    case "render":
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture(.private, .renderTarget)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
    case "blit":
        let rows = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
        let e = cb.makeBlitCommandEncoder()!
        e.copy(from: rows, sourceOffset: 0, sourceBytesPerRow: size * 4, sourceBytesPerImage: size * size * 4,
               sourceSize: MTLSize(width: size, height: size, depth: 1), to: texture(.private, .shaderRead),
               destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        e.endEncoding()
    case "compute":
        let e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(try! device.makeComputePipelineState(function: library.makeFunction(name: "k")!))
        e.setBuffer(device.makeBuffer(length: 256, options: .storageModeShared)!, offset: 0, index: 0)
        e.dispatchThreads(MTLSize(width: 64, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        e.endEncoding()
    case "replace":
        let bytes = [UInt8](repeating: 7, count: size * size * 4)
        texture(.shared, .shaderRead).replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                                              withBytes: bytes, bytesPerRow: size * 4)
    default:
        fatalError("unknown step \(step)")
    }
    cb.commit()
    cb.waitUntilCompleted()
    print(step, footprint())
}
