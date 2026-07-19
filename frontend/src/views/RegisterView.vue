<script setup lang="ts">
// Placeholder auth surface. The real invite-gated vee-validate + zod form
// (posting to POST /api/v1/registration) is implemented in issue #038.
</script>

<template>
  <div>
    <h1 class="text-lg font-semibold tracking-tight text-ink">Create account</h1>
    <p class="mt-1 text-sm text-ink-muted">Registration is invite-only.</p>

    <p class="mt-6 rounded-md border border-dashed border-line-strong p-4 text-sm text-ink-muted">
      The registration form lands in issue #038.
    </p>

    <p class="mt-6 text-sm text-ink-muted">
      Already have an account?
      <RouterLink :to="{ name: 'login' }" class="font-medium text-accent hover:text-accent-hi">
        Sign in
      </RouterLink>
    </p>
  </div>
</template>
