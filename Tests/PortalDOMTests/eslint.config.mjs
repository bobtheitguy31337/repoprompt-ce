const sharedRules = {
  "no-constant-condition": "error",
  "no-dupe-keys": "error",
  "no-unreachable": "error",
  "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
  "no-undef": "error",
};

export default [
  {
    files: ["../../Sources/RepoPromptServiceHTTP/Resources/Portal/portal.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: {
        document: "readonly",
        fetch: "readonly",
        Intl: "readonly",
        location: "readonly",
        navigator: "readonly",
        window: "readonly",
      },
    },
    rules: sharedRules,
  },
  {
    files: ["portal.test.mjs"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        Buffer: "readonly",
        process: "readonly",
        setTimeout: "readonly",
      },
    },
    rules: sharedRules,
  },
];
