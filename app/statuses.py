"""Single source of truth for the order a report moves through.

The backend validates against it, writes the value on-chain with it, and
sends it to the app in every complaint response (`status_flow`) so the
Flutter timeline draws exactly these steps.
"""

STATUS_FLOW = ('SUBMITTED', 'UNDER_REVIEW', 'INVESTIGATING', 'ACTION_TAKEN', 'RESOLVED')
