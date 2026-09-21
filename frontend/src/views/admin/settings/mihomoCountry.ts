export interface CountryFilter {
  mode: 'off' | 'exclude' | 'include'
  codes: string[]
  allow_unknown: boolean
}
export interface CountryNode {
  name: string
  state: string
  country_code?: string
  country_checked_at?: string
  country_error?: string
  country_blocked?: boolean
}
