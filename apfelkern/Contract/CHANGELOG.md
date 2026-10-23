# Contract 1.7.0

- Add `POST /v1/providers/{provider}/login`, `GET` and `DELETE /v1/provider-logins/{id}`, and `POST /v1/provider-logins/{id}/responses` with the `ProviderLoginSession`, `ProviderLoginPrompt`, and `ProviderLoginEvent` schemas. Unknown or expired sessions, including those lost on restart, return 410.
- Add `authMethods`, `credentialType`, and `activeLoginId` to `Provider`.
- `DELETE /v1/providers/{provider}` now removes an account sign-in as well as an API key. Clients that only set API keys keep working unchanged.
