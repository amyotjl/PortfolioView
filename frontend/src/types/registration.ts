import { z } from 'zod'
import { sessionSchema, sessionUserSchema } from './session'

/**
 * POST /api/v1/registration (requires `invite_code`) -> 201, identical shape to
 * the session response (`{ user: {...} }`) + a session cookie. Modelled as an
 * alias so callers read intent, while staying a single source of truth.
 */
export const registrationSchema = sessionSchema

export type Registration = z.infer<typeof registrationSchema>
export { sessionUserSchema as registeredUserSchema }
