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
import { sessionSchema } from '@/types'
import { useAuthStore } from '@/stores/auth'
import { loginSchema } from '@/forms/auth'
import { mapApiError } from '@/lib/formErrors'
import { safeRedirectTarget } from '@/lib/redirect'
import { inputTextPt, buttonPt } from '@/primevue/pt'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const formError = shallowRef<string | null>(null)

const { defineField, handleSubmit, errors, isSubmitting, setErrors } = useForm({
  validationSchema: toTypedSchema(loginSchema),
  initialValues: { email_address: '', password: '' },
})

const [email, emailAttrs] = defineField('email_address')
const [password, passwordAttrs] = defineField('password')

// Carry any ?redirect= onto the register link so the round-trip is preserved.
const registerTo = computed(() => ({
  name: 'register' as const,
  query: route.query.redirect ? { redirect: route.query.redirect } : {},
}))

const onSubmit = handleSubmit(async (values) => {
  formError.value = null
  try {
    const data = await apiPost('/session', values, { schema: sessionSchema })
    auth.setUser(data.user)
    await router.push(safeRedirectTarget(route.query.redirect))
  } catch (err) {
    const mapped = mapApiError(err, ['email_address', 'password'])
    if (Object.keys(mapped.fieldErrors).length > 0) setErrors(mapped.fieldErrors)
    formError.value = mapped.formMessage
  }
})
</script>

<template>
  <div>
    <h1 class="text-lg font-semibold tracking-tight text-ink">Sign in</h1>
    <p class="mt-1 text-sm text-ink-muted">Welcome back.</p>

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

      <FormField label="Password" :error="errors.password">
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="password"
            v-bind="passwordAttrs"
            type="password"
            autocomplete="current-password"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <Button
        type="submit"
        class="mt-2 w-full"
        :label="isSubmitting ? 'Signing in…' : 'Sign in'"
        :disabled="isSubmitting"
        :pt="buttonPt"
      />
    </form>

    <p class="mt-6 text-sm text-ink-muted">
      Need an account?
      <RouterLink :to="registerTo" class="font-medium text-accent hover:text-accent-hi">
        Register
      </RouterLink>
    </p>
  </div>
</template>
