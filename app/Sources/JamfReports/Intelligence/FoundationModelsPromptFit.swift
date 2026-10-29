// Gated like the generators that call it; see FoundationModelsInsightGenerator.swift.
#if canImport(FoundationModels) && compiler(>=6.4)
import Foundation
import FoundationModels

/// Shared by all three generators: sizes a prompt to the room the 4,096-token window leaves
/// after the instructions, the `@Generable` schema and the response, which all share it.
@available(macOS 27, *)
enum PromptFit {
    /// Tokens kept free for the model's response.
    static let responseReserve = 600

    /// Low temperature: every generator restates supplied figures and does not create.
    static let options = GenerationOptions(temperature: 0.1)

    /// Renders the prompt for `render(maxApproxTokens)` so it fits, then runs `body`; on
    /// `contextSizeExceeded` it renders at half the room and runs `body` once more, unless
    /// `canRetry` says output was already delivered (a stream that has yielded).
    static func run<T>(
        model: SystemLanguageModel, instructions: String, schema: GenerationSchema?,
        render: (Int) -> String, canRetry: () -> Bool = { true },
        body: (String) async throws -> T
    ) async throws -> T {
        var room = await room(model: model, instructions: instructions, schema: schema)
        for attempt in 0..<2 {
            let prompt = await fitted(model: model, room: room, render: render)
            do {
                return try await body(prompt)
            } catch LanguageModelError.contextSizeExceeded where attempt == 0 && canRetry() {
                AppLogger.platform.notice("Prompt exceeded the context window; retrying smaller")
                room /= 2
            }
        }
        preconditionFailure("unreachable: the second attempt returns or throws")
    }

    /// The context size less the tokens of the instructions and schema and the response
    /// reserve. A tokenizer failure is logged and estimated from characters.
    static func room(
        model: SystemLanguageModel, instructions: String, schema: GenerationSchema?
    ) async -> Int {
        var fixed = responseReserve
        do {
            fixed += try await model.tokenCount(for: Instructions(instructions))
            if let schema { fixed += try await model.tokenCount(for: schema) }
        } catch {
            AppLogger.platform.notice(
                "Token count failed, estimating: \(error.localizedDescription, privacy: .private)")
            fixed += instructions.count / FleetInsightInput.charsPerToken
                + (schema == nil ? 0 : 400)
        }
        return max(200, model.contextSize - fixed)
    }

    /// Renders at `room` tokens, then halves until the tokenizer agrees it fits (three times
    /// at most; a failed count keeps the heuristic render).
    static func fitted(
        model: SystemLanguageModel, room: Int, render: (Int) -> String
    ) async -> String {
        var budget = room
        var prompt = render(budget)
        for _ in 0..<3 {
            do {
                if try await model.tokenCount(for: prompt) <= room { break }
            } catch {
                AppLogger.platform.notice(
                    "Token count failed: \(error.localizedDescription, privacy: .private)")
                break
            }
            budget /= 2
            prompt = render(budget)
        }
        return prompt
    }
}
#endif
