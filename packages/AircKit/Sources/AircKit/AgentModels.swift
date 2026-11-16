// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// The Airc Agent's models and task levels (docs/design/agent.md, "Bring your own model" and "Task levels and cost").
// Data, so a release can update the lists without touching the loop.

public enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case anthropic, openai

    public var name: String { self == .anthropic ? "Anthropic" : "OpenAI" }
    /// Where people get a key.
    public var keyPage: String {
        self == .anthropic ? "https://platform.claude.com/settings/keys" : "https://platform.openai.com/api-keys"
    }
    public var defaultBase: String { self == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com" }
    public var models: [AgentModel] { AgentModel.all.filter { $0.provider == self } }
    public var defaultModel: AgentModel { models.first { $0.isDefault } ?? models[0] }
}

public struct AgentModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let provider: AgentProvider
    /// US dollars per million input and output tokens (list price), for the panel's estimate.
    public let inputPrice: Double
    public let outputPrice: Double
    public let isDefault: Bool
    /// Anthropic's server-side refusal fallback (`fallbacks: "default"`) is offered for this model.
    public let refusalFallback: Bool

    public static let all: [AgentModel] = [
        AgentModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", provider: .anthropic, inputPrice: 4, outputPrice: 20, isDefault: true, refusalFallback: true),
        AgentModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", provider: .anthropic, inputPrice: 2, outputPrice: 10, isDefault: false, refusalFallback: true),
        AgentModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", provider: .anthropic, inputPrice: 0.1, outputPrice: 0.5, isDefault: false, refusalFallback: false),
        AgentModel(id: "claude-fable-5-2", name: "Claude Fable 5.2", provider: .anthropic, inputPrice: 8, outputPrice: 40, isDefault: false, refusalFallback: true),
        AgentModel(id: "gpt-6-astra", name: "GPT-6 Astra", provider: .openai, inputPrice: 10, outputPrice: 50, isDefault: true, refusalFallback: false),
        AgentModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", provider: .openai, inputPrice: 2, outputPrice: 10, isDefault: false, refusalFallback: false),
        AgentModel(id: "gpt-6.1-terra", name: "GPT-6.1 Terra", provider: .openai, inputPrice: 1, outputPrice: 5, isDefault: false, refusalFallback: false),
        AgentModel(id: "gpt-6-luna", name: "GPT-6 Luna", provider: .openai, inputPrice: 0.1, outputPrice: 0.5, isDefault: false, refusalFallback: false),
    ]

    public static func find(_ id: String) -> AgentModel? { all.first { $0.id == id } }

    /// Dollars for this much use (cache reads at a tenth of the input price, writes at 1.25×).
    public func cost(_ u: AgentUsage) -> Double {
        let fresh = Double(max(0, u.input)) * inputPrice
        let cached = Double(u.cacheRead) * inputPrice * 0.1 + Double(u.cacheWrite) * inputPrice * 1.25
        return (fresh + cached + Double(u.output) * outputPrice) / 1_000_000
    }
}

/// Tokens used, summed over a run's model turns. `input` excludes cached reads and writes.
public struct AgentUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
    public var total: Int { input + output + cacheRead + cacheWrite }
    public static func + (a: AgentUsage, b: AgentUsage) -> AgentUsage {
        AgentUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// Quick, or keep going until done.
public enum AgentLevel: String, Codable, Sendable, CaseIterable {
    case quick, long

    public var name: String { self == .quick ? "Quick" : "Keep going" }
    public var budget: AgentBudget {
        switch self {
        case .quick: return AgentBudget(steps: 25, seconds: 180, tokens: 300_000, effort: "medium")
        case .long: return AgentBudget(steps: 200, seconds: 1800, tokens: 3_000_000, effort: "high")
        }
    }
}

public struct AgentBudget: Equatable, Sendable {
    public var steps: Int
    public var seconds: TimeInterval
    public var tokens: Int
    /// Anthropic `output_config.effort` / OpenAI `reasoning.effort`.
    public var effort: String
    public init(steps: Int, seconds: TimeInterval, tokens: Int, effort: String) {
        self.steps = steps
        self.seconds = seconds
        self.tokens = tokens
        self.effort = effort
    }

    /// Why a run must stop now, or nil.
    public func exceeded(steps s: Int, elapsed: TimeInterval, usage: AgentUsage) -> String? {
        if s >= steps { return "step limit (\(steps) steps)" }
        if elapsed >= seconds { return "time limit (\(Int(seconds / 60)) min)" }
        if usage.total >= tokens { return "token limit (\(tokens / 1000)k)" }
        return nil
    }
}
