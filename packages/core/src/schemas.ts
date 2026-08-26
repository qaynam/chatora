// Decoders for CosenseApi's read responses. Every field is `optionalWith` with a default
// (or, for fields the plain type itself marks `?`, `optionalWith({ exact: true })`), so
// decoding a response the server actually sends never fails: a missing field falls back
// to a zero value and an unrecognized extra field is dropped (effect Schema's default
// Struct behavior). This mirrors — and extends one level deeper than — the `?? ...`
// defaulting docs/ARCHITECTURE.md describes for the old hand-rolled parser, since these
// item shapes were previously cast, not validated, at all.
//
// Each schema's decoded type is checked against its types.ts counterpart where it's
// actually used — `CosenseApiShape`'s method signatures in api.ts — rather than through a
// `Schema.Schema<Decoded, Encoded>` annotation here: `default` vs `exact` optionalWith
// fields disagree on whether `undefined` is part of the *encoded* value type, so a single
// mapped "wire shape" type can't describe every schema below without repeating that
// per-field choice a second time.
import { Schema } from 'effect'

const optionalString = Schema.optionalWith(Schema.String, { default: () => '' })
const optionalNumber = Schema.optionalWith(Schema.Number, { default: () => 0 })
const optionalBoolean = Schema.optionalWith(Schema.Boolean, { default: () => false })
const optionalNullableString = Schema.optionalWith(Schema.NullOr(Schema.String), {
  default: () => null,
})

// The saved page filters shown in Cosense's web list UI, e.g. { type: 'icon', value: 'qaynam' }.
export const PageFilterSchema = Schema.Struct({
  type: optionalString,
  value: optionalString,
})

export const MeSchema = Schema.Struct({
  id: optionalString,
  name: optionalString,
  displayName: optionalString,
  email: Schema.optionalWith(Schema.String, { exact: true }),
  photo: Schema.optionalWith(Schema.String, { exact: true }),
  pageFilters: Schema.optionalWith(Schema.Array(PageFilterSchema), { default: () => [] }),
})

export const ProjectSummarySchema = Schema.Struct({
  id: optionalString,
  name: optionalString,
  displayName: optionalString,
  publicVisible: optionalBoolean,
  isMember: optionalBoolean,
  usersCount: optionalNumber,
  created: optionalNumber,
  updated: optionalNumber,
})

// `/api/projects/<name>` — everything `/api/projects` returns plus the project's own
// settings. `uploadImageTo` is the one that decides where a pasted image goes.
export const ProjectDetailSchema = Schema.Struct({
  id: optionalString,
  name: optionalString,
  displayName: optionalString,
  uploadImageTo: optionalString,
  uploadFileTo: optionalString,
  gyazoTeamsName: optionalNullableString,
})

export const UserRefSchema = Schema.Struct({
  id: optionalString,
  name: Schema.optionalWith(Schema.String, { exact: true }),
  displayName: Schema.optionalWith(Schema.String, { exact: true }),
})

export const PageSummarySchema = Schema.Struct({
  id: optionalString,
  title: optionalString,
  image: optionalNullableString,
  descriptions: Schema.optionalWith(Schema.Array(Schema.String), { default: () => [] }),
  user: Schema.optionalWith(Schema.NullOr(UserRefSchema), { exact: true }),
  linked: optionalNumber,
  views: optionalNumber,
  linesCount: optionalNumber,
  charsCount: optionalNumber,
  created: optionalNumber,
  updated: optionalNumber,
  // Unix seconds of the *requesting* user's last visit, which is what makes
  // `updated > accessed` an unread test (the same one Cosense's web grid draws
  // its blue border from). 0 when the field is absent, i.e. never visited.
  accessed: optionalNumber,
  // Sort weight for pinned pages; 0 means not pinned.
  pin: optionalNumber,
})

// Every line carries its own authorship and mtime, which is what Cosense's telomere is
// drawn from: how recently the line changed, and whether it changed since your last visit.
export const PageDetailLineSchema = Schema.Struct({
  id: optionalString,
  text: optionalString,
  updated: optionalNumber,
  userId: optionalString,
})

export const RelatedPageSchema = Schema.Struct({
  id: optionalString,
  title: optionalString,
  titleLc: optionalString,
  image: optionalNullableString,
  descriptions: Schema.optionalWith(Schema.Array(Schema.String), { default: () => [] }),
  linksLc: Schema.optionalWith(Schema.Array(Schema.String), { default: () => [] }),
  linked: optionalNumber,
  pageRank: optionalNumber,
  updated: optionalNumber,
  relation: Schema.optionalWith(
    Schema.Union(
      Schema.Literal('outgoing'),
      Schema.Literal('incoming'),
      Schema.Literal('bidirectional'),
    ),
    { exact: true },
  ),
})

export const SearchResultPageSchema = Schema.Struct({
  id: optionalString,
  title: optionalString,
  words: Schema.optionalWith(Schema.Array(Schema.String), { default: () => [] }),
  lines: Schema.optionalWith(Schema.Array(Schema.String), { default: () => [] }),
  views: optionalNumber,
  linked: optionalNumber,
  updated: optionalNumber,
})

export const VectorResultPageSchema = Schema.Struct({
  title: optionalString,
  image: optionalNullableString,
  score: optionalNumber,
  exists: optionalBoolean,
  id: Schema.optionalWith(Schema.String, { exact: true }),
  linked: Schema.optionalWith(Schema.Number, { exact: true }),
})

export const TitleEntrySchema = Schema.Struct({
  id: optionalString,
  title: optionalString,
  titleLc: optionalString,
  updated: optionalNumber,
  image: optionalNullableString,
})

// --- envelope shapes (endpoint-specific wrappers, not part of the public type surface) ---

export const ProjectsResponseSchema = Schema.Struct({
  projects: Schema.optionalWith(Schema.Array(ProjectSummarySchema), { default: () => [] }),
})

export const ListPagesResponseSchema = Schema.Struct({
  count: optionalNumber,
  pages: Schema.optionalWith(Schema.Array(PageSummarySchema), { default: () => [] }),
})

// The v2 page endpoint returns HTTP 200 + `persistent: false` for a title with no real
// page yet (docs/ARCHITECTURE.md); `title` is left un-defaulted here (not `optionalString`)
// so CosenseApi.getPage can fall back to the requested title exactly when the field is
// absent, matching the old code's `data.title ?? title` (not defaulting past an explicit "").
export const PageV2ResponseSchema = Schema.Struct({
  id: optionalString,
  title: Schema.optionalWith(Schema.String, { exact: true }),
  commitId: optionalString,
  persistent: Schema.optionalWith(Schema.Boolean, { default: () => true }),
  lines: Schema.optionalWith(Schema.Array(PageDetailLineSchema), { default: () => [] }),
  created: optionalNumber,
  updated: optionalNumber,
  accessed: optionalNumber,
  views: optionalNumber,
  linked: optionalNumber,
  linesCount: optionalNumber,
  charsCount: optionalNumber,
  // Sort weight for pinned pages; 0 means not pinned.
  pin: optionalNumber,
  pageRank: optionalNumber,
  snapshotCount: optionalNumber,
  user: Schema.optionalWith(Schema.NullOr(UserRefSchema), { exact: true }),
  lastUpdateUser: Schema.optionalWith(Schema.NullOr(UserRefSchema), { exact: true }),
  users: Schema.optionalWith(Schema.Array(UserRefSchema), { default: () => [] }),
})

// `/api/projects/<name>/users` — the page body names its author by id alone, so this is
// where an id becomes something to show. Members who have left survive in
// `memberSnapshots`, which is why an author can still be named after they are gone.
//
// It also carries `projectId`, and is the only route to it that a personal access token can
// take: plain `/api/projects/<name>` answers a PAT with 401 (cosense-cli reaches for this
// same endpoint in resolveProjectId.ts for exactly that reason).
export const ProjectUsersResponseSchema = Schema.Struct({
  projectId: optionalString,
  users: Schema.optionalWith(Schema.Array(UserRefSchema), { default: () => [] }),
  memberSnapshots: Schema.optionalWith(
    Schema.Array(Schema.Struct({ data: Schema.optionalWith(UserRefSchema, { exact: true }) })),
    { default: () => [] },
  ),
})

export const Links1HopResponseSchema = Schema.Struct({
  links1hop: Schema.optionalWith(Schema.Array(RelatedPageSchema), { default: () => [] }),
})

export const Links2HopResponseSchema = Schema.Struct({
  links2hop: Schema.optionalWith(Schema.Array(RelatedPageSchema), { default: () => [] }),
})

export const SearchFullTextResponseSchema = Schema.Struct({
  count: optionalNumber,
  existsExactTitleMatch: optionalBoolean,
  pages: Schema.optionalWith(Schema.Array(SearchResultPageSchema), { default: () => [] }),
})

export const SearchVectorResponseSchema = Schema.Struct({
  pages: Schema.optionalWith(Schema.Array(VectorResultPageSchema), { default: () => [] }),
})

// /search/titles responds with either a bare array or `{ pages: [...] }`. CosenseApi
// picks between these two schemas itself (Array.isArray on the raw body) rather than
// decoding a Schema.Union of them — TS can't narrow a decoded union by Array.isArray as
// cleanly as it can narrow the *raw* `unknown` body, and checking the wire shape first is
// exactly what the endpoint's contract already turns on.
export const TitleEntryArraySchema = Schema.Array(TitleEntrySchema)
export const TitleEntryEnvelopeSchema = Schema.Struct({
  pages: Schema.optionalWith(Schema.Array(TitleEntrySchema), { default: () => [] }),
})

const PagePreviewSchema = Schema.Struct({
  title: Schema.optionalWith(Schema.String, { exact: true }),
  persistent: Schema.optionalWith(Schema.Boolean, { exact: true }),
  lines: Schema.optionalWith(Schema.Array(PageDetailLineSchema), { exact: true }),
})

export const PreviewResponseSchema = Schema.Struct({
  pageDelete: Schema.optionalWith(Schema.Boolean, { default: () => false }),
  previewId: optionalString,
  expireAt: optionalString,
  pagePreview: Schema.optionalWith(Schema.NullOr(PagePreviewSchema), { default: () => null }),
})

export const SubmitResponseSchema = Schema.Struct({
  pageDeleted: Schema.optionalWith(Schema.Struct({ title: optionalString }), { exact: true }),
  commitId: optionalString,
  page: Schema.optionalWith(Schema.NullOr(Schema.Struct({ title: optionalString })), {
    default: () => null,
  }),
  titleChanged: Schema.optionalWith(Schema.Struct({ from: optionalString, to: optionalString }), {
    exact: true,
  }),
})
