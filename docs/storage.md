# Private Storage

The SDKs upload, download, remove objects, and create short-lived signed
download URLs. Use a private bucket and scope every object to its owning user.
The public project key identifies the application; Storage row policies enforce
ownership.

## Create a private bucket

Run once in the project's SQL console:

```sql
insert into storage.buckets (id, name, public)
values ('private-files', 'private-files', false)
on conflict (id) do update set public = false;
```

Store each user's files under the first path segment equal to their user ID, for
example `USER_UUID/avatar.png`. Then add policies:

```sql
create policy private_files_read_own on storage.objects
  for select to authenticated
  using (
    bucket_id = 'private-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy private_files_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'private-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy private_files_update_own on storage.objects
  for update to authenticated
  using (
    bucket_id = 'private-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'private-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy private_files_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'private-files'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
```

Policies are examples for a private user-owned bucket. Run them once; policy
names must be unique within the table. Test upload, download, update and delete
as two separate users. Verify that the second user cannot guess or read the
first user's object path.

## Use an SDK

JavaScript:

```ts
const photos = stayo.storage.from('private-files')
await photos.upload(`${user.id}/avatar.png`, file, {
  contentType: 'image/png',
  upsert: true,
})
const avatar = await photos.download(`${user.id}/avatar.png`)
const signedURL = await photos.createSignedUrl(`${user.id}/avatar.png`, 60)
await photos.remove([`${user.id}/avatar.png`])
```

Swift and Kotlin expose the same operations; see their
[package references](README.md#api-references-and-examples). Signed URLs are
bearer links: anyone holding one can access its object until it expires. Share
them only with an intended recipient and keep their lifetime short.

## Limits

Version `0.1.0` buffers upload/download data in memory; large-file streaming is
not implemented. Object path segments are encoded separately, and traversal,
empty path segments, and backslashes are rejected. HTTP redirects do not receive
the original authorization credentials.

Storage fixture tests do not prove a hosted bucket configuration. Follow the
[acceptance report](release-status.md#verification) for the remaining device, TLS and
isolated-host checks.
