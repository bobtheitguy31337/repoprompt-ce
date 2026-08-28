import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol

/// Browser-safe adapter between durable provider interaction payloads and the
/// typed Agent Mode interaction contract. Opaque provider routing metadata
/// never crosses this boundary.
public enum AgentInteractionPresentationAdapter {
    public static func project(
        _ value: InteractionSnapshot,
        turnID: String,
        mutable: Bool
    ) -> AgentPresentationInteractionWire {
        let providerPayload = try? JSONDecoder.serviceDecoder.decode(
            ProviderInteractionPayload.self,
            from: value.payload
        )
        let askUser = HeadlessAskUser.isAskUserPayload(value.payload)
        let input: AgentPresentationInteractionInputWire?
        let prompt: String
        if askUser, let questionnaire = questionnaire(from: value.payload) {
            input = .questionnaire(questions: questionnaire.questions)
            prompt = questionnaire.prompt
        } else if let providerPayload {
            prompt = bounded(providerPayload.prompt, limit: 16_384)
            let choices = providerPayload.choices.prefix(100).map {
                AgentPresentationChoiceWire(id: $0, displayName: $0)
            }
            input = choices.isEmpty
                ? .freeText(placeholder: nil, multiline: true)
                : .singleChoice(choices: Array(choices), allowsCustom: false)
        } else {
            prompt = "Provider interaction"
            input = .freeText(placeholder: nil, multiline: true)
        }
        let actionable = value.state == .pending || value.state == .deliveryIntent
        return .init(
            interactionID: value.interactionID,
            kind: value.kind == .approval ? .approval : .question,
            state: value.state.rawValue,
            prompt: prompt,
            choices: providerPayload?.choices.map { bounded($0, limit: 1_024) } ?? [],
            input: input,
            resolution: providerPayload?.resolution
                ?? (askUser && value.state != .pending
                    ? HeadlessAskUser.resolutionLabel(from: value.payload)
                    : nil),
            turnID: turnID,
            liveTail: actionable,
            requiresAttention: actionable,
            mutable: mutable && value.state == .pending,
            revision: value.revision
        )
    }

    public static func compile(
        response: AgentPresentationInteractionResponseWire,
        for interaction: InteractionSnapshot
    ) throws -> Data {
        guard interaction.state == .pending else {
            throw ServiceAPIError(code: .interactionSettled, message: "Interaction is no longer pending")
        }
        if HeadlessAskUser.isAskUserPayload(interaction.payload) {
            guard let questionnaire = questionnaire(from: interaction.payload) else {
                throw ServiceAPIError(code: .invalidRequest, message: "The interaction questionnaire is invalid")
            }
            guard case let .questionnaire(submitted) = response else {
                throw ServiceAPIError(code: .invalidRequest, message: "This interaction requires questionnaire answers")
            }
            return try compileQuestionnaire(submitted, questions: questionnaire.questions)
        }

        let providerPayload = try? JSONDecoder.serviceDecoder.decode(
            ProviderInteractionPayload.self,
            from: interaction.payload
        )
        let choices = providerPayload?.choices ?? []
        if !choices.isEmpty {
            guard case let .choice(choiceID, customText) = response,
                  choices.contains(choiceID)
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "The selected interaction choice is invalid")
            }
            guard customText == nil || customText?.isEmpty == true else {
                throw ServiceAPIError(code: .invalidRequest, message: "This interaction does not accept a custom answer")
            }
            let normalized = choiceID.lowercased()
            return try JSONSerialization.data(withJSONObject: [
                "optionId": choiceID,
                "decision": choiceID,
                "accepted": ["accept", "approve", "allow", "yes"].contains(normalized),
            ], options: [.sortedKeys])
        }

        guard case let .text(text) = response else {
            throw ServiceAPIError(code: .invalidRequest, message: "This interaction requires a text answer")
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.utf8.count <= 64_000 else {
            throw ServiceAPIError(code: .invalidRequest, message: "The interaction answer is empty or exceeds its portal bound")
        }
        return try JSONSerialization.data(
            withJSONObject: ["text": answer, "answer": answer, "custom_response": answer],
            options: [.sortedKeys]
        )
    }

    private struct Questionnaire {
        let prompt: String
        let questions: [AgentPresentationQuestionWire]
    }

    private static func questionnaire(from data: Data) -> Questionnaire? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = string(object["title"])
            ?? string(object["question"])
            ?? "The agent needs your response."
        let rawQuestions = object["questions"] as? [Any] ?? []
        var seen = Set<String>()
        let questions = rawQuestions.prefix(100).compactMap { raw -> AgentPresentationQuestionWire? in
            guard let row = raw as? [String: Any] else { return nil }
            let id = string(row["id"] ?? row["questionId"]) ?? "question-\(seen.count + 1)"
            guard seen.insert(id).inserted else { return nil }
            let prompt = string(row["question"] ?? row["prompt"] ?? row["header"]) ?? id
            let rawOptions = row["options"] as? [Any] ?? row["choices"] as? [Any] ?? []
            var choiceIDs = Set<String>()
            let choices = rawOptions.prefix(100).compactMap { option -> AgentPresentationChoiceWire? in
                let id: String
                let display: String
                let detail: String?
                if let value = option as? String {
                    id = value
                    display = value
                    detail = nil
                } else if let value = option as? [String: Any] {
                    display = string(value["label"] ?? value["displayName"] ?? value["id"]) ?? "Option"
                    id = string(value["id"]) ?? display
                    detail = string(value["description"] ?? value["detailText"])
                } else {
                    return nil
                }
                guard choiceIDs.insert(id).inserted else { return nil }
                return .init(
                    id: bounded(id, limit: 512),
                    displayName: bounded(display, limit: 2_048),
                    detailText: detail.map { bounded($0, limit: 4_096) }
                )
            }
            return .init(
                id: bounded(id, limit: 512),
                prompt: bounded(prompt, limit: 16_384),
                choices: choices,
                allowsMultiple: bool(row["allows_multiple"] ?? row["allowsMultiple"]),
                allowsCustom: row["allows_custom"] == nil && row["allowsCustom"] == nil
                    ? true
                    : bool(row["allows_custom"] ?? row["allowsCustom"]),
                required: row["required"] == nil ? true : bool(row["required"])
            )
        }
        if questions.isEmpty, let question = string(object["question"]) {
            return Questionnaire(
                prompt: title,
                questions: [.init(id: "question", prompt: bounded(question, limit: 16_384))]
            )
        }
        guard !questions.isEmpty else { return nil }
        return Questionnaire(prompt: bounded(title, limit: 16_384), questions: questions)
    }

    private static func compileQuestionnaire(
        _ submitted: [AgentPresentationQuestionAnswerWire],
        questions: [AgentPresentationQuestionWire]
    ) throws -> Data {
        guard submitted.count <= questions.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Too many questionnaire answers were submitted")
        }
        let definitions = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
        var seen = Set<String>()
        var values: [String: Any] = [:]
        for answer in submitted {
            guard seen.insert(answer.questionID).inserted,
                  let question = definitions[answer.questionID]
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "A questionnaire answer ID is unknown or duplicated")
            }
            guard Set(answer.selectedChoiceIDs).count == answer.selectedChoiceIDs.count else {
                throw ServiceAPIError(code: .invalidRequest, message: "A questionnaire choice was duplicated")
            }
            let choices = Dictionary(uniqueKeysWithValues: question.choices.map { ($0.id, $0.displayName) })
            guard answer.selectedChoiceIDs.allSatisfy({ choices[$0] != nil }),
                  question.allowsMultiple || answer.selectedChoiceIDs.count <= 1
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "A questionnaire choice is invalid")
            }
            let custom = answer.customText?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard custom?.utf8.count ?? 0 <= 64_000,
                  question.allowsCustom || custom == nil || custom?.isEmpty == true
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "A questionnaire custom answer is invalid")
            }
            let hasAnswer = !answer.selectedChoiceIDs.isEmpty || !(custom ?? "").isEmpty
            guard !answer.skipped || !hasAnswer else {
                throw ServiceAPIError(code: .invalidRequest, message: "A skipped questionnaire answer cannot include a response")
            }
            guard answer.skipped || !question.required || hasAnswer else {
                throw ServiceAPIError(code: .invalidRequest, message: "A required questionnaire answer is missing")
            }
            let answerCount = answer.selectedChoiceIDs.count + ((custom ?? "").isEmpty ? 0 : 1)
            guard question.allowsMultiple || answerCount <= 1 else {
                throw ServiceAPIError(code: .invalidRequest, message: "A single-select questionnaire answer contains multiple responses")
            }
            let selected = answer.selectedChoiceIDs.compactMap { choices[$0] }
            var renderedAnswers = selected
            if let custom, !custom.isEmpty { renderedAnswers.append(custom) }
            let customResponse: Any = custom?.isEmpty == false ? custom! : NSNull()
            values[answer.questionID] = [
                "answers": renderedAnswers,
                "selected_options": selected,
                "custom_response": customResponse,
                "skipped": answer.skipped,
            ]
        }
        for question in questions where question.required && !seen.contains(question.id) {
            throw ServiceAPIError(code: .invalidRequest, message: "A required questionnaire answer is missing")
        }
        return try JSONSerialization.data(withJSONObject: [
            "answers": values,
            "timed_out": false,
            "skipped": false,
            "elapsed_seconds": 0,
        ], options: [.sortedKeys])
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }
}
