<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import InputText from 'primevue/inputtext'
import Button from 'primevue/button'
import FormField from '@/components/ui/FormField.vue'
import FormAlert from '@/components/ui/FormAlert.vue'
import { apiPost } from '@/api/client'
import { registrationSchema } from '@/types'
import { useAuthStore } from '@/stores/auth'
import { registerSchema } from '@/forms/auth'
import { mapApiError } from '@/lib/formErrors'
import { safeRedirectTarget } from '@/lib/redirect'
import { inputTextPt, buttonPt } from '@/primevue/pt'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const formError = shallowRef<string | null>(null)

const { defineField, handleSubmit, errors, isSubmitting, setErrors } = useForm({
  validationSchema: toTypedSchema(registerSchema),
  initialValues: {
    email_address: '',
    password: '',
    password_confirmation: '',
    invite_code: '',
  },
})

const [email, emailAttrs] = defineField('email_address')
const [password, passwordAttrs] = defineField('password')
const [passwordConfirmation, passwordConfirmationAttrs] = defineField('password_confirmation')
const [inviteCode, inviteCodeAttrs] = defineField('invite_code')

const loginTo = computed(() => ({
  name: 'login' as const,
  query: route.query.redirect ? { redirect: route.query.redirect } : {},
}))

const onSubmit = handleSubmit(async (values) => {
  formError.value = null
  try {
    const data = await apiPost('/registration', values, { schema: registrationSchema })
    // Registration signs the new user in server-side; adopt the session locally.
    auth.setUser(data.user)
    await router.push(safeRedirectTarget(route.query.redirect))
  } catch (err) {
    const mapped = mapApiError(err, [
      'email_address',
      'password',
      'password_confirmation',
      'invite_code',
    ])
    if (Object.keys(mapped.fieldErrors).length > 0) setErrors(mapped.fieldErrors)
    formError.value = mapped.formMessage
  }
})
</script>

<template>
  <div>
    <h1 class="text-lg font-semibold tracking-tight text-ink">Create account</h1>
    <p class="mt-1 text-sm text-ink-muted">Registration is invite-only.</p>

    <FormAlert :message="formError" class="mt-6" />

    <form class="mt-6 flex flex-col gap-4" novalidate @submit.prevent="onSubmit">
      <FormField label="Email" :error="errors.email_address">
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="email"
            v-bind="emailAttrs"
            type="email"
            autocomplete="email"
            inputmode="email"
            placeholder="you@example.com"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField label="Password" :error="errors.password" hint="At least 8 characters.">
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="password"
            v-bind="passwordAttrs"
            type="password"
            autocomplete="new-password"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField label="Confirm password" :error="errors.password_confirmation">
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="passwordConfirmation"
            v-bind="passwordConfirmationAttrs"
            type="password"
            autocomplete="new-password"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField label="Invite code" :error="errors.invite_code" hint="Ask the owner for an invite.">
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="inviteCode"
            v-bind="inviteCodeAttrs"
            type="text"
            autocomplete="off"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <Button
        type="submit"
        class="mt-2 w-full"
        :label="isSubmitting ? 'Creating account…' : 'Create account'"
        :disabled="isSubmitting"
        :pt="buttonPt"
      />
    </form>

    <p class="mt-6 text-sm text-ink-muted">
      Already have an account?
      <RouterLink :to="loginTo" class="font-medium text-accent hover:text-accent-hi">
        Sign in
      </RouterLink>
    </p>
  </div>
</template>
