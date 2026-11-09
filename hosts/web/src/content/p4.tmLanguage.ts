/**
 * Hand-written TextMate grammar for P4_16. The keyword list is the `morekeywords` of the
 * `p4style` listing style in the LDWG deck (/uni/year_7/slidesLDWG/presentation/main.tex),
 * extended with the P4_16 reserved words that style leaves to its C base language.
 * Kept to simple, engine-neutral regular expressions (works with Oniguruma and the JS engine).
 */
export const p4Keywords = [
  "header", "parser", "control", "table", "action", "state", "transition", "select", "apply",
  "extract", "bit", "typedef", "struct", "inout", "out", "packet_in", "default_action", "key",
  "actions", "size", "lpm", "mark_to_drop", "isValid", "NoAction", "const",
] as const;

const controlWords = ["if", "else", "switch", "return", "exit", "transition", "select", "default", "verify", "for", "in"];
const declWords = [
  "header", "header_union", "parser", "control", "table", "action", "state", "struct", "enum", "error",
  "extern", "package", "typedef", "type", "const", "match_kind", "instantiation", "apply", "entries",
];
const modifiers = ["in", "out", "inout", "default_action", "key", "actions", "size", "const", "exact", "ternary", "lpm", "range", "optional", "selector"];
const typeWords = ["bit", "bool", "int", "varbit", "void", "string", "packet_in", "packet_out", "tuple"];
const builtins = ["extract", "emit", "mark_to_drop", "isValid", "setValid", "setInvalid", "NoAction", "lookahead", "advance"];

const word = (words: readonly string[]) => `\\b(?:${[...new Set(words)].join("|")})\\b`;

export const p4Grammar = {
  name: "p4",
  scopeName: "source.p4",
  fileTypes: ["p4"],
  patterns: [
    { include: "#comments" },
    { include: "#preprocessor" },
    { include: "#annotations" },
    { include: "#strings" },
    { include: "#numbers" },
    { include: "#keywords" },
    { include: "#types" },
    { include: "#builtins" },
    { include: "#operators" },
  ],
  repository: {
    comments: {
      patterns: [
        { name: "comment.line.double-slash.p4", match: "//.*$" },
        { name: "comment.block.p4", begin: "/\\*", end: "\\*/" },
      ],
    },
    preprocessor: { name: "meta.preprocessor.p4", match: "^\\s*#\\s*(?:include|define|undef|if|ifdef|ifndef|else|elif|endif|error|pragma)\\b.*$" },
    annotations: { name: "meta.annotation.p4", match: "@[A-Za-z_][A-Za-z0-9_]*" },
    strings: { name: "string.quoted.double.p4", begin: "\"", end: "\"", patterns: [{ name: "constant.character.escape.p4", match: "\\\\." }] },
    numbers: {
      patterns: [
        { name: "constant.numeric.width.p4", match: "\\b[0-9]+[ws](?:0[xXbBoOdD])?[0-9a-fA-F_]+\\b" },
        { name: "constant.numeric.hex.p4", match: "\\b0[xX][0-9a-fA-F_]+\\b" },
        { name: "constant.numeric.bin.p4", match: "\\b0[bB][01_]+\\b" },
        { name: "constant.numeric.decimal.p4", match: "\\b[0-9][0-9_]*\\b" },
        { name: "constant.language.p4", match: "\\b(?:true|false)\\b" },
      ],
    },
    keywords: {
      patterns: [
        { name: "keyword.control.p4", match: word(controlWords) },
        { name: "keyword.declaration.p4", match: word(declWords) },
        { name: "storage.modifier.p4", match: word(modifiers) },
      ],
    },
    types: {
      patterns: [
        { name: "storage.type.builtin.p4", match: `${word(typeWords)}(?:\\s*<[^>]*>)?` },
        { name: "entity.name.type.p4", match: "\\b[A-Z][A-Za-z0-9_]*\\b" },
      ],
    },
    builtins: { name: "support.function.p4", match: word(builtins) },
    operators: { name: "keyword.operator.p4", match: "\\+\\+|&&&|\\.\\.|\\|\\+\\||\\|-\\||<<|>>|<=|>=|==|!=|&&|\\|\\||[-+*/%&|^~!<>=?:]" },
  },
};
