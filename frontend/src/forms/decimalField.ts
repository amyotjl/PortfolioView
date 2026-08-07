import { z } from 'zod'

/**
 * The one decimal-string field validator, shared by every money/shares form
 * (issue #80 extraction).
 *
 * DECIMALS STAY STRINGS. shares/price/fees/amount are `numeric(20,8)`,
 * `numeric(16,6)` and `numeric(12,2)` server-side and cross the wire as JSON
 * strings (docs/API_SHAPES.md). So forms bind them to text inputs and validate
 * the *string*, rather than using a numeric input that would round-trip through
 * IEEE-754 — an 8dp share count is exactly the value a float loses. Nothing here
 * ever calls parseFloat; we only check shape and sign, and hand the untouched
 * string to the API. In particular the schema must NOT coerce: `'5.10'` has to
 * survive byte-identical, and `z.coerce.number()` would emit `5.1`.
 *
 * WHY IT LIVES HERE. It was written once in `forms/transaction.ts` and then
 * near-duplicated as `amountField` in `forms/recurring.ts`; `forms/cash.ts` would
 * have been the third copy. Three consumers, one copy — and the extraction is
 * BYTE-IDENTICAL to the transaction version (regex, refine order, and every
 * message string), because `transaction.spec.ts` asserts those messages and
 * `recurring.spec.ts` asserts the same ones through the old duplicate.
 *
 * Sign is deliberately not modelled: the regex rejects a leading `+`/`-`
 * outright, which is also why the cash API emits a movement's `amount` as an
 * unsigned magnitude — an edit form repopulating from a signed GET would hand
 * `-500` straight to this validator.
 */

/** Plain decimal, no exponent/sign tricks: `12`, `12.5`, `.5`, `0.00000001`. */
export const DECIMAL = /^(?:\d+(?:\.\d*)?|\.\d+)$/

/**
 * Validate a decimal string by shape, then by scale, then by sign — all without
 * arithmetic. Sign is decided by "does it contain a nonzero digit", which is
 * exact for an unsigned decimal and avoids a float comparison entirely.
 */
export function decimalField(options: {
  label: string
  scale: number
  allowZero: boolean
}): z.ZodType<string> {
  const { label, scale, allowZero } = options
  return z
    .string()
    .trim()
    .min(1, `${label} is required`)
    .refine((value) => DECIMAL.test(value), `${label} must be a number`)
    .refine((value) => {
      const decimals = value.split('.')[1] ?? ''
      return decimals.length <= scale
    }, `${label} allows at most ${scale} decimal place${scale === 1 ? '' : 's'}`)
    .refine(
      (value) => allowZero || /[1-9]/.test(value),
      `${label} must be greater than zero`,
    )
}
