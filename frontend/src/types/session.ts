import { z } from 'zod'

/**
 * GET /api/v1/session  -> { user: { id, email_address } }
 * POST /api/v1/session -> 201, same shape + HttpOnly session cookie.
 * A signed-out GET returns the 401 error envelope (and still sets the XSRF cookie).
 */
export const sessionUserSchema = z.object({
  id: z.number(),
  email_address: z.string(),
})

export const sessionSchema = z.object({
  user: sessionUserSchema,
})

export type SessionUser = z.infer<typeof sessionUserSchema>
export type Session = z.infer<typeof sessionSchema>
