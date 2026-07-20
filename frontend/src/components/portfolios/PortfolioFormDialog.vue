<script setup lang="ts">
import { computed, shallowRef, watch } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import Dialog from 'primevue/dialog'
import Select from 'primevue/select'
import InputText from 'primevue/inputtext'
import Button from 'primevue/button'
import FormField from '@/components/ui/FormField.vue'
import FormAlert from '@/components/ui/FormAlert.vue'
import { useBenchmarksQuery, benchmarkLabel } from '@/composables/useBenchmarks'
import { useCreatePortfolio, useUpdatePortfolio } from '@/composables/usePortfolios'
import { portfolioFormSchema } from '@/forms/portfolio'
import { mapApiError } from '@/lib/formErrors'
import { inputTextPt, selectPt, buttonPt, dialogPt } from '@/primevue/pt'
import type { Portfolio } from '@/types'

/**
 * Create (portfolio = null) or edit (portfolio set) dialog. Owns its vee-validate
 * form and runs the Colada mutation itself (which invalidates the list cache), so
 * the parent only toggles `visible` and passes the target. Server 422 details
 * are mapped back onto the fields.
 */
const visible = defineModel<boolean>('visible', { required: true })
const props = defineProps<{ portfolio?: Portfolio | null }>()
const emit = defineEmits<{ saved: [] }>()

const isEdit = computed(() => Boolean(props.portfolio))
const title = computed(() => (isEdit.value ? 'Edit portfolio' : 'New portfolio'))

const { benchmarks } = useBenchmarksQuery()
const benchmarkOptions = computed(() =>
  benchmarks.value.map((b) => ({ label: benchmarkLabel(b), value: b.id })),
)

const createMutation = useCreatePortfolio()
const updateMutation = useUpdatePortfolio()

const formError = shallowRef<string | null>(null)

const { defineField, handleSubmit, errors, isSubmitting, setErrors, resetForm } = useForm({
  validationSchema: toTypedSchema(portfolioFormSchema),
  initialValues: { name: '', benchmark_id: null },
})

const [name, nameAttrs] = defineField('name')
const [benchmarkId] = defineField('benchmark_id')

// Seed the form to the current target every time the dialog opens.
watch(visible, (open) => {
  if (!open) return
  formError.value = null
  resetForm({
    values: props.portfolio
      ? { name: props.portfolio.name, benchmark_id: props.portfolio.benchmark_id }
      : { name: '', benchmark_id: null },
  })
})

const onSubmit = handleSubmit(async (values) => {
  formError.value = null
  try {
    if (props.portfolio) {
      await updateMutation.mutateAsync({ id: props.portfolio.id, input: values })
    } else {
      await createMutation.mutateAsync(values)
    }
    emit('saved')
    visible.value = false
  } catch (err) {
    const mapped = mapApiError(err, ['name', 'benchmark_id'])
    if (Object.keys(mapped.fieldErrors).length > 0) setErrors(mapped.fieldErrors)
    formError.value = mapped.formMessage
  }
})
</script>

<template>
  <Dialog
    v-model:visible="visible"
    modal
    :header="title"
    :draggable="false"
    :dismissable-mask="!isSubmitting"
    :closable="!isSubmitting"
    :pt="dialogPt"
  >
    <form class="flex flex-col gap-4" novalidate @submit.prevent="onSubmit">
      <FormAlert :message="formError" />

      <FormField label="Name" :error="errors.name" required>
        <template #default="{ id, invalid, describedby }">
          <InputText
            :id="id"
            v-model="name"
            v-bind="nameAttrs"
            type="text"
            placeholder="e.g. Retirement"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="inputTextPt"
          />
        </template>
      </FormField>

      <FormField
        label="Benchmark"
        :error="errors.benchmark_id"
        hint="Compared against your cash-flow-matched deposits."
      >
        <template #default="{ id, invalid, describedby }">
          <Select
            :input-id="id"
            v-model="benchmarkId"
            :options="benchmarkOptions"
            option-label="label"
            option-value="value"
            placeholder="No benchmark"
            show-clear
            class="w-full"
            :invalid="invalid"
            :aria-describedby="describedby"
            :pt="selectPt"
          />
        </template>
      </FormField>
    </form>

    <template #footer>
      <Button
        label="Cancel"
        severity="secondary"
        :disabled="isSubmitting"
        :pt="buttonPt"
        @click="visible = false"
      />
      <Button
        :label="isSubmitting ? 'Saving…' : isEdit ? 'Save changes' : 'Create portfolio'"
        :disabled="isSubmitting"
        :pt="buttonPt"
        @click="onSubmit"
      />
    </template>
  </Dialog>
</template>
