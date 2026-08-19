import Foundation
import CoreML
import Combine

@MainActor
class Wav2VecEngine: ObservableObject {
    static let shared = Wav2VecEngine()
    
    private var model: MLModel?
    private var decoder: CTCDecoder?
    
    @Published var isModelLoaded = false
    
    private init() {}
    
    func loadModel() async {
        guard !isModelLoaded else { return }
        
        // Use a background task for loading
        await Task.detached(priority: .userInitiated) {
            do {
                guard let modelURL = Bundle.main.url(forResource: "Wav2Vec2_Indonesian_FP16", withExtension: "mlmodelc") ?? Bundle.main.url(forResource: "Wav2Vec2_Indonesian_FP16", withExtension: "mlmodelc", subdirectory: "AI/Wav2Vec_STT") else {
                    print("Could not find Wav2Vec2_Indonesian_FP16.mlmodelc in bundle.")
                    return
                }
                
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndGPU 
                let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
                
                // Initialize Decoder
                guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json") ?? Bundle.main.url(forResource: "vocab", withExtension: "json", subdirectory: "AI/Wav2Vec_STT"),
                      let lexiconURL = Bundle.main.url(forResource: "lexicon", withExtension: "txt") ?? Bundle.main.url(forResource: "lexicon", withExtension: "txt", subdirectory: "AI/Wav2Vec_STT"),
                      let mappingURL = Bundle.main.url(forResource: "canonical_mapping", withExtension: "json") ?? Bundle.main.url(forResource: "canonical_mapping", withExtension: "json", subdirectory: "AI/Wav2Vec_STT") else {
                    print("Could not find vocab, lexicon, or mapping")
                    return
                }
                
                // 1. Load original words
                let lexiconData = try String(contentsOf: lexiconURL, encoding: .utf8)
                var words = [String]()
                for line in lexiconData.components(separatedBy: .newlines) {
                    if line.isEmpty { continue }
                    let parts = line.components(separatedBy: "\t")
                    if parts.count > 0 { words.append(parts[0]) }
                }
                
                let mappingData = try Data(contentsOf: mappingURL)
                var mapping = try JSONSerialization.jsonObject(with: mappingData, options: []) as? [String: String] ?? [:]
                
                var dynamicWords = words
                for (v, c) in mapping {
                    if !dynamicWords.contains(v) {
                        dynamicWords.append(v)
                    }
                }
                
                let trie = PrefixTrie(words: dynamicWords)
                let loadedDecoder = CTCDecoder(vocabPath: vocabURL.path, trie: trie, dynamicMapping: mapping)
                
                await MainActor.run {
                    self.model = loadedModel
                    self.decoder = loadedDecoder
                    self.isModelLoaded = true
                    print("Model and Decoder successfully loaded!")
                }
            } catch {
                print("Failed to load CoreML model: \(error)")
            }
        }.value
    }
    
    func predict(audioData: [Float], isLivePreview: Bool = false) async -> String? {
        guard let model = model, let decoder = decoder else { return nil }
        
        return await Task.detached(priority: .userInitiated) {
            do {
                // 1. Prepare MLMultiArray input
                let seqLength = audioData.count
                guard seqLength > 0 else { return nil }
                
                // Audio Bucketing for GPU/ANE dynamic shape memory safety
                // We pad the audio to 1-second boundaries (16000 samples) so the Metal backend only allocates a few fixed buffers
                let bucketSize = 16000
                let paddedLength = ((seqLength + bucketSize - 1) / bucketSize) * bucketSize
                
                let inputShape = [1, NSNumber(value: paddedLength)]
                let inputMultiArray = try MLMultiArray(shape: inputShape, dataType: .float32)
                
                // Copy audio data, pad the rest with White Noise!
                // CRITICAL FIX: Because the audio is Z-score normalized (mean 0, variance 1), 
                // padding with pure 0.0 creates a mathematically impossible flatline "cliff" that corrupts the CNN's forward receptive field,
                // causing the final phoneme of a word to be dropped or destroyed! 
                // By padding with uniform white noise (variance 1.0), the CNN sees a natural acoustic boundary.
                let pointer = inputMultiArray.dataPointer.assumingMemoryBound(to: Float32.self)
                for i in 0..<seqLength {
                    pointer[i] = audioData[i]
                }
                for i in seqLength..<paddedLength {
                    pointer[i] = Float.random(in: -1.732...1.732) // sqrt(3) -> Variance of 1.0
                }
                
                let input = try MLDictionaryFeatureProvider(dictionary: ["input_values": inputMultiArray])
                
                // 2. Predict
                let prediction = try model.prediction(from: input)
                guard let logitsArray = prediction.featureValue(for: "logits")?.multiArrayValue else {
                    print("No logits output found")
                    return nil
                }
                
                // logits shape is typically [1, paddedTimeSteps, 32]
                let shape = logitsArray.shape
                let vocabSize = shape[shape.count - 1].intValue
                
                // Decode the full padded length to capture the CNN's forward receptive field
                let actualTimeSteps = paddedLength / 320
                
                var logits2D: [[Float]] = Array(repeating: Array(repeating: 0.0, count: vocabSize), count: actualTimeSteps)
                
                let outPointer = UnsafeMutablePointer<Float32>(OpaquePointer(logitsArray.dataPointer))
                var offset = 0
                for t in 0..<actualTimeSteps {
                    for v in 0..<vocabSize {
                        logits2D[t][v] = outPointer[offset]
                        offset += 1
                    }
                }
                
                // 3. Decode
                let rawResult = decoder.decode(logits: logits2D, beamWidth: 10, isLivePreview: isLivePreview)
                return rawResult
                
            } catch {
                print("Inference error: \(error)")
                return nil
            }
        }.value
    }
}
