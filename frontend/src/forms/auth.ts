import { z } from 'zod'

/**
 * CLIENT-SIDE request/form schemas for the auth flows. These are deliberately
 * separate from `@/types` (which mirrors API *response* shapes): they validate
 * what the user types before it is POSTed. The server remains authoritative — a
 * 422 envelope is still mapped back onto these same fields (see mapApiError).
 *
 * `.email(...)` string-shorthand messages are verified to work under zod 4.
 */

export const loginSchema = z.object({
  email_address: z.string().min(1, 'Email is required').email('Enter a valid email address'),
  // Login stays lenient on the password (presence only): an existing account's
  // password must be submittable regardless of the rules in force when it was set.
  password: z.string().min(1, 'Password is required'),
})

export const registerSchema = z
  .object({
    email_address: z.string().min(1, 'Email is required').email('Enter a valid email address'),
    password: z.string().min(8, 'Use at least 8 characters'),
    password_confirmation: z.string().min(1, 'Confirm your password'),
    invite_code: z.string().min(1, 'Invite code is required'),
  })
  .refine((data) => data.password === data.password_confirmation, {
    error: 'Passwords do not match',
    path: ['password_confirmation'],
  })

export type LoginValues = z.infer<typeof loginSchema>
export type RegisterValues = z.infer<typeof registerSchema>
