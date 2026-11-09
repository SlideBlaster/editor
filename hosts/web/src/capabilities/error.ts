/**
 * A browser capability failure with a stable machine-readable category.
 */
export class CapabilityError extends Error {
  code: string;
  /**
   * @param {string} code
   * @param {string} message
   */
  constructor(code: string, message: string) {
    super(message);
    this.name = "CapabilityError";
    this.code = code;
  }
}
