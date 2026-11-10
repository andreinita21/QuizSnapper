import Foundation

enum Defaults {
    /// Changing this? Bump `legacyQuizSystemPrompts` in SettingsStore so existing profiles follow.
    static let quizSystemPrompt = """
    You answer quiz and exam questions from screenshots.
    The screenshots may show one question split across several images (for example a page that was scrolled). Treat all images as a single context, in the order given.

    Identify the question and every answer option, think it through carefully, then reply in exactly this format:
    Line 1: only the letter(s) of the correct answer(s), comma-separated — e.g. `B` or `A, C`.
    Line 2: a very short justification (under 20 words), in the same language as the question.

    If the options are not labeled with letters, label them A, B, C… in the order shown and say so.
    If there are several questions, answer each on its own line as `1: B`, `2: A, D`.
    If the question is not multiple choice but asks you to type into blanks, gaps or text boxes, make line 1 exactly `FILL: value1; value2; value3` — only the values to type, in the order the boxes appear, separated by semicolons. Use the same format for a single box (`FILL: value`). No letters, no numbering, no explanation on that line.
    If no question is visible, reply exactly `No quiz found`.
    """

    static let quizUserPrompt = "Answer the question in the screenshot(s)."

    static let explainSystemPrompt = """
    You are a patient expert tutor. The user sends screenshots of a question or exercise (possibly split across several images, in order).
    Start with the final answer on the first line. Then explain step by step why it is correct and why the other options are wrong.
    Reply in the same language as the question. Use concise Markdown.
    """

    static let explainUserPrompt = "Solve this and explain your reasoning."

    static let openSystemPrompt = """
    The user sends screenshots of a question, task or piece of code (possibly across several images, in order).
    Give a complete, correct answer. For code, output the full working solution in a code block, then a short explanation.
    Reply in the same language as the question.
    """

    static let openUserPrompt = "Answer the question / solve the task shown."

    static func makeInitialSettings() -> AppSettings {
        var s = AppSettings()
        let anthropic = ProviderConfig(name: "Claude", preset: .anthropic)
        let lmStudio = ProviderConfig(name: "LM Studio", preset: .lmStudio)
        s.providers = [anthropic, lmStudio]

        let quiz = Profile(name: "Quiz — quick answer", icon: "checkmark.circle.fill", providerID: anthropic.id,
                           model: "claude-opus-5-5", effort: .medium, maxTokens: 8192,
                           systemPrompt: quizSystemPrompt, userPrompt: quizUserPrompt, menuBarDisplay: .letter)
        let explain = Profile(name: "Explain in detail", icon: "graduationcap.fill", providerID: anthropic.id,
                              model: "claude-opus-5-5", effort: .high, maxTokens: nil, showReasoning: true,
                              systemPrompt: explainSystemPrompt, userPrompt: explainUserPrompt, menuBarDisplay: .firstLine)
        let open = Profile(name: "Open question / code", icon: "chevron.left.forwardslash.chevron.right",
                           providerID: anthropic.id, model: "claude-opus-5-5", effort: .high, maxTokens: nil,
                           systemPrompt: openSystemPrompt, userPrompt: openUserPrompt, menuBarDisplay: .iconOnly)
        let local = Profile(name: "Quiz — local model", icon: "desktopcomputer", providerID: lmStudio.id,
                            model: "", effort: .auto, maxTokens: nil,
                            systemPrompt: quizSystemPrompt, userPrompt: quizUserPrompt, menuBarDisplay: .letter)
        s.profiles = [quiz, explain, open, local]
        s.activeProfileID = quiz.id

        for (action, combo) in KeyCombo.defaults {
            s.shortcuts[action.rawValue] = combo
        }
        return s
    }
}
