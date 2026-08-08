import { describe, expect, it } from 'vitest'
import {
  allocationScopeNotice,
  cashKindLabel,
  cashMagnitude,
  isKnownCashKind,
  negativeCashNotice,
  projectedCashCents,
  signedCashAmount,
  withdrawalProjectionNotice,
} from './cash'
import { centsToDecimalString } from './money'

describe('cashKindLabel', () => {
  it('labels all six stored kinds', () => {
    expect(cashKindLabel('deposit')).toBe('Deposit')
    expect(cashKindLabel('withdrawal')).toBe('Withdrawal')
    expect(cashKindLabel('interest')).toBe('Interest')
    expect(cashKindLabel('dividend_cash')).toBe('Cash dividend')
    expect(cashKindLabel('tax')).toBe('Tax')
    expect(cashKindLabel('fee')).toBe('Fee')
  })

  it('falls through to the raw string for a kind this build does not know', () => {
    // The same decision as modelling `kind` as z.string() rather than a zod enum: a
    // newer backend kind should render ugly, not blank the table or throw.
    expect(cashKindLabel('rebate')).toBe('rebate')
    expect(cashKindLabel('')).toBe('')
    expect(isKnownCashKind('rebate')).toBe(false)
    expect(isKnownCashKind('dividend_cash')).toBe(true)
  })
})

describe('cashMagnitude', () => {
  it('strips the wire sign in exact cents', () => {
    // The wire is signed in both directions, so "how much moved" always has to drop
    // the sign — for the edit form and for any sentence the kind name already
    // directs ("delete the withdrawal of $2,500.00").
    expect(cashMagnitude('-2500.0')).toBe('2500.00')
    expect(cashMagnitude('10000.0')).toBe('10000.00')
    expect(cashMagnitude('+4.95')).toBe('4.95')
    expect(cashMagnitude('-0.29')).toBe('0.29')
  })

  it('pads to cents, because the API drops trailing zeros', () => {
    // BigDecimal#to_s("F") emits '0.0'/'5.1', not '0.00'/'5.10'.
    expect(cashMagnitude('5.1')).toBe('5.10')
    expect(cashMagnitude('0.0')).toBe('0.00')
    expect(cashMagnitude('1000')).toBe('1000.00')
  })

  it('returns an unparseable figure as itself rather than NaN', () => {
    expect(cashMagnitude('')).toBe('')
    expect(cashMagnitude('-abc')).toBe('abc')
  })
})

describe('signedCashAmount', () => {
  it('signs the two unambiguous directions from an unsigned magnitude', () => {
    expect(signedCashAmount('deposit', '5000.00')).toBe('+$5,000.00')
    expect(signedCashAmount('withdrawal', '5000.00')).toBe('-$5,000.00')
    expect(signedCashAmount('interest', '1.25')).toBe('+$1.25')
    expect(signedCashAmount('dividend_cash', '42.00')).toBe('+$42.00')
  })

  it('invents NO sign for a kind that is genuinely bidirectional', () => {
    // `tax` covers withholding AND a refund; `fee` covers a charge AND a
    // reimbursement. Guessing a direction would be worse than letting the Type
    // column say it.
    expect(signedCashAmount('tax', '30.00')).toBe('$30.00')
    expect(signedCashAmount('fee', '4.95')).toBe('$4.95')
    expect(signedCashAmount('rebate', '4.95')).toBe('$4.95')
  })

  it('never double-signs a string that already carries a sign', () => {
    expect(signedCashAmount('dividend_cash', '-42.00')).toBe('-$42.00')
    expect(signedCashAmount('withdrawal', '-5000.00')).toBe('-$5,000.00')
    expect(signedCashAmount('fee', '+4.95')).toBe('+$4.95')
  })
})

describe('projectedCashCents', () => {
  /**
   * THE FLOAT PROBE the issue asks for, and it has to assert the CENTS rather than
   * the message: `formatCurrency` rounds -0.21999999999999997 to '-$0.22' too, so a
   * text assertion would not discriminate a parseFloat implementation at all.
   */
  it('subtracts in exact integer cents, not in floats', () => {
    expect(projectedCashCents('0.07', '0.29')).toBe(-22)
    expect(centsToDecimalString(projectedCashCents('0.07', '0.29') as number)).toBe('-0.22')
    // For the record: 0.07 - 0.29 in IEEE-754 is -0.21999999999999997.
    expect(0.07 - 0.29).not.toBe(-0.22)
  })

  it('treats the withdrawal amount as a magnitude regardless of an incoming sign', () => {
    expect(projectedCashCents('100.00', '250.00')).toBe(-15_000)
    expect(projectedCashCents('100.00', '-250.00')).toBe(-15_000)
  })

  it('returns null rather than guessing when either side is unparseable', () => {
    expect(projectedCashCents('100.00', 'abc')).toBeNull()
    expect(projectedCashCents('n/a', '5.00')).toBeNull()
  })
})

describe('negativeCashNotice', () => {
  it('says nothing when the portfolio does not track cash (null is NOT zero)', () => {
    expect(negativeCashNotice(null)).toBeNull()
  })

  it('says nothing at exactly flat, which is a tracked state, not an absent one', () => {
    expect(negativeCashNotice('0.00')).toBeNull()
    expect(negativeCashNotice('1200.00')).toBeNull()
  })

  it('quotes the negative balance and states the direction of BOTH distortions', () => {
    const message = negativeCashNotice('-3240.00')
    expect(message).toBe(
      'Cash is -$3,240.00. Withdrawals and trades have drawn more than this portfolio ' +
        'records receiving — usually because some deposits are not recorded yet. Until ' +
        'they are, total value reads low and the return percentage reads high.',
    )
    // The direction is checked arithmetic, not a hunch: if deposits are understated
    // by D, cash is low by D and net_deposits is low by D, so total_return is
    // UNCHANGED while return/deposits is OVERSTATED. Reversing these would be worse
    // than saying nothing.
    expect(message).toContain('total value reads low')
    expect(message).toContain('return percentage reads high')
  })

  it('is tense-neutral, so the same string serves a fact and a projection', () => {
    const message = negativeCashNotice('-10.00') as string
    for (const pastTense of ['was ', 'were ', 'has been', 'had ']) {
      expect(message.toLowerCase(), pastTense).not.toContain(pastTense)
    }
  })

  it('does not fire on a sub-cent residual (the test is cent-rounded)', () => {
    expect(negativeCashNotice('-0.000004')).toBeNull()
    expect(negativeCashNotice('-0.004')).toBeNull()
    // A real cent, however, does.
    expect(negativeCashNotice('-0.01')).toContain('-$0.01')
  })

  it('does not assert a single cause — an honest over-withdrawal reads the same', () => {
    expect(negativeCashNotice('-100.00')).toContain('usually because')
  })

  it('returns null rather than throwing on an unparseable balance', () => {
    expect(negativeCashNotice('n/a')).toBeNull()
  })
})

describe('withdrawalProjectionNotice', () => {
  it('projects the balance the withdrawal would leave, hedging the as-of', () => {
    expect(
      withdrawalProjectionNotice({ cashBalance: '1200.00', amount: '5000.00' }),
    ).toBe(
      'This portfolio’s cash balance is $1,200.00 as of the latest figures. ' +
        'Withdrawing $5,000.00 takes it to -$3,800.00. That is allowed — ' +
        'it just means some deposits are probably missing.',
    )
  })

  it('hedges "as of the latest figures" because /summary is current, not as-of the date', () => {
    // Claiming date precision we do not have is the failure mode
    // `sellPreflightMessage`'s two-branch design exists to avoid.
    const message = withdrawalProjectionNotice({ cashBalance: '10.00', amount: '20.00' }) as string
    expect(message).toContain('as of the latest figures')
  })

  it('states plainly that the entry is allowed — nothing here blocks the save', () => {
    expect(withdrawalProjectionNotice({ cashBalance: '10.00', amount: '20.00' })).toContain(
      'That is allowed',
    )
  })

  it('says nothing when the withdrawal leaves the balance at or above zero', () => {
    expect(withdrawalProjectionNotice({ cashBalance: '5000.00', amount: '1200.00' })).toBeNull()
    // Exactly flat is not negative.
    expect(withdrawalProjectionNotice({ cashBalance: '5000.00', amount: '5000.00' })).toBeNull()
  })

  it('says nothing when the portfolio does not track cash', () => {
    expect(withdrawalProjectionNotice({ cashBalance: null, amount: '5000.00' })).toBeNull()
  })

  it('says nothing for a half-typed or unparseable amount', () => {
    expect(withdrawalProjectionNotice({ cashBalance: '10.00', amount: '' })).toBeNull()
    expect(withdrawalProjectionNotice({ cashBalance: '10.00', amount: '  ' })).toBeNull()
    expect(withdrawalProjectionNotice({ cashBalance: '10.00', amount: '.' })).toBeNull()
  })

  it('projects in exact cents — the float probe, end to end', () => {
    const message = withdrawalProjectionNotice({ cashBalance: '0.07', amount: '0.29' })
    expect(message).toContain('$0.07')
    expect(message).toContain('$0.29')
    expect(message).toContain('-$0.22')
  })

  it('deepens an already-negative balance rather than refusing to speak', () => {
    expect(withdrawalProjectionNotice({ cashBalance: '-100.00', amount: '50.00' })).toContain(
      '-$150.00',
    )
  })
})

describe('allocationScopeNotice', () => {
  it('states the holdings-only scope and the cash remainder with its share', () => {
    expect(
      allocationScopeNotice({
        holdingsValue: '96400.00',
        currentValue: '100000.00',
        cashBalance: '3600.00',
      }),
    ).toBe(
      'Allocation covers your holdings only — $96,400.00 of $100,000.00 total. ' +
        'The remaining $3,600.00 is cash (3.60%).',
    )
  })

  it('says nothing when the portfolio does not track cash', () => {
    expect(
      allocationScopeNotice({
        holdingsValue: '96400.00',
        currentValue: '96400.00',
        cashBalance: null,
      }),
    ).toBeNull()
  })

  it('says nothing at exactly flat — there is no divergence to disclose', () => {
    // Tracked but flat means /allocations' total_value and /summary's current_value
    // genuinely agree. NOTE: this is about THIS caption only; the Cash stat tile must
    // still render at '0.00' (see summaryTiles.spec.ts).
    expect(
      allocationScopeNotice({
        holdingsValue: '100000.00',
        currentValue: '100000.00',
        cashBalance: '0.00',
      }),
    ).toBeNull()
  })

  /**
   * THE NEGATIVE BRANCH, which is the state the whole feature's headline warning is
   * about — and the one the first version of this caption got incoherent. Measured on
   * screen before the fix:
   *
   *   "Allocation covers your holdings only — $65,799.30 of $24,807.40 total.
   *    The remaining -$40,991.90 is cash (-165.24%)."
   *
   * Three lies in one sentence: holdings are not a subset of a smaller total, a
   * negative figure is not a "remainder", and a share of a whole smaller than its
   * part is not a percentage of anything. So the negative branch gets its own
   * wording and NO percentage at all.
   */
  it('states the scope truthfully when cash is negative, with no percentage', () => {
    const message = allocationScopeNotice({
      holdingsValue: '65799.30',
      currentValue: '24807.40',
      cashBalance: '-40991.90',
    })
    expect(message).toBe(
      'Allocation covers your holdings only — $65,799.30. Cash of -$40,991.90 sits outside ' +
        'it and brings this portfolio’s total down to $24,807.40.',
    )
    // No percentage, because there is no share to state.
    expect(message).not.toContain('%')
    // And no "remaining", which would claim holdings are part of a smaller total.
    expect(message).not.toContain('remaining')
  })

  it('does not duplicate the negative-cash advisory sitting above it', () => {
    // negativeCashNotice owns the CAUSE ("some deposits are not recorded yet") and the
    // consequence for the return percentage. This caption states scope only — two
    // notices saying the same thing is how a user learns to skip both.
    const message = allocationScopeNotice({
      holdingsValue: '12400.00',
      currentValue: '9160.00',
      cashBalance: '-3240.00',
    })
    expect(message).not.toMatch(/deposit|return|withdraw/i)
    expect(message).toContain('$12,400.00')
    expect(message).toContain('-$3,240.00')
    expect(message).toContain('$9,160.00')
  })

  it('is tense-neutral, like every other string in this module', () => {
    // The same sentence has to read correctly as a statement of fact today and after a
    // refetch tomorrow; a past tense would be wrong in one of them.
    const message = allocationScopeNotice({
      holdingsValue: '12400.00',
      currentValue: '9160.00',
      cashBalance: '-3240.00',
    })
    expect(message).not.toMatch(/\b(was|were|had|has been)\b/)
  })

  it('omits the share when the total is zero rather than emitting NaN%', () => {
    // Defensive, and only reachable with a positive balance against a zero total (a
    // negative balance takes the branch above). Kept because `cashCents / 0` is
    // Infinity and would render as an Infinity%.
    const message = allocationScopeNotice({
      holdingsValue: '-500.00',
      currentValue: '0.00',
      cashBalance: '500.00',
    })
    expect(message).toBe(
      'Allocation covers your holdings only — -$500.00 of $0.00 total. The remaining $500.00 is cash.',
    )
  })

  it('says nothing until both totals have arrived', () => {
    expect(
      allocationScopeNotice({ holdingsValue: undefined, currentValue: undefined, cashBalance: '1.00' }),
    ).toBeNull()
  })
})
