/**
 * ECharts modular registration (tree-shaken). We import from `echarts/core` and
 * register ONLY the charts + components the dashboard actually uses, then
 * re-export the `vue-echarts` component so views import both from one place.
 *
 * Importing this module for its side effect (the `use([...])` call) is required
 * before any <VChart> renders. The pure option builders in this folder never
 * import this file — they only need ECharts *types* (erased at build), which is
 * what keeps them unit-testable without pulling the runtime.
 */
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { CandlestickChart, LineChart, BarChart, PieChart } from 'echarts/charts'
import {
  GridComponent,
  TooltipComponent,
  LegendComponent,
  DataZoomComponent,
  AxisPointerComponent,
  TitleComponent,
  MarkLineComponent,
} from 'echarts/components'
import VChart from 'vue-echarts'

use([
  CanvasRenderer,
  CandlestickChart,
  LineChart,
  BarChart,
  PieChart,
  GridComponent,
  TooltipComponent,
  LegendComponent,
  DataZoomComponent,
  AxisPointerComponent,
  TitleComponent,
  MarkLineComponent,
])

export { VChart }
