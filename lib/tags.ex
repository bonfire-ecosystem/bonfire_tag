Bonfire.Common.Config.require_extension_config!(:bonfire_tag)

defmodule Bonfire.Tag.Tags do

  import Bonfire.Common.Config, only: [repo: 0]
  alias Bonfire.Common.Utils

  # alias CommonsPub.Users.User
  alias Bonfire.Tag
  alias Bonfire.Tag.Queries

  # alias CommonsPub.Characters

  def cursor(), do: &[&1.id]
  def test_cursor(), do: &[&1["id"]]

  @doc """
  Retrieves a single tag by arbitrary filters.
  Used by:
  * GraphQL Item queries
  * ActivityPub integration
  * Various parts of the codebase that need to query for tags (inc. tests)
  """
  def one(filters), do: repo().single(Queries.query(Tag, filters))

  @doc """
  Retrieves a list of tags by arbitrary filters.
  Used by:
  * Various parts of the codebase that need to query for tags (inc. tests)
  """
  def many(filters \\ []), do: {:ok, repo().all(Queries.query(Tag, filters))}


  def get(id) do
    if Bonfire.Common.Utils.is_ulid(id) do
      one(id: id)
    else
      one(username: id)
    end
  end

  # def many(filters \\ []), do: {:ok, repo().all(Queries.query(Tag, filters))}

  def prefix("Community") do
    "&"
  end

  def prefix("User") do
    "@"
  end

  def prefix(_) do
    "+"
  end

  def maybe_find_tag(user, taggable, attrs) when is_binary(taggable) do
    with {:ok, tag} <- get(taggable) do
      {:ok, tag}
    else _e ->
        with {:ok, pointer} <- Bonfire.Common.Pointers.one(taggable) do
          pointer
        else _e ->
            if Utils.module_enabled?(Bonfire.Me.Identity.Users) do
              with {:ok, user} <- Bonfire.Me.Identity.Users.by_username(taggable) do
                user
              end
            end
        end
    end
  end

### Functions for creating tags ###

  @doc """
  Create a Tag from an existing object (eg. Bonfire.Geolocate.Geolocation)
  """
  def maybe_make_tag(user, context) do
    maybe_make_tag(user, context, %{})
  end

  def maybe_make_tag(user, id, _) when is_number(id) do
    with {:ok, t} <- maybe_taxonomy_tag(user, id) do
      {:ok, t}
    else
      _e ->
        {:error, "Please provide a pointer"}
    end
  end

  def maybe_make_tag(user, pointer_id, attrs) when is_binary(pointer_id) do
    if Bonfire.Common.Utils.is_numeric(pointer_id) do
      maybe_make_tag(user, String.to_integer(pointer_id), attrs)
    else
      with {:ok, tag} <- get(pointer_id) do
        {:ok, tag}
      else
        _e ->
          with {:ok, pointer} <- Bonfire.Common.Pointers.one(pointer_id) do
            maybe_make_tag(user, pointer, attrs)
            # _e ->
            #   with {:ok, pointer} <- Bonfire.Common.Pointers.one(pointer_id) do
            #     maybe_make_tag(user, pointer, attrs)
            #   end
          end
      end
    end
  end

  def maybe_make_tag(user, %Pointers.Pointer{} = pointer, attrs) do
    with context = Bonfire.Common.Pointers.follow!(pointer) do
      maybe_make_tag(user, context, attrs)
    end
  end

  def maybe_make_tag(user, %{id: id} = context, attrs) do
    with {:ok, tag} <- get(id) do
      {:ok, tag}
    else
      _e -> make_tag(user, context, attrs)
    end
  end

  @doc """
  Create a tag mixin for an existing poitable object (you usually want to use maybe_make_tag instead)
  """
  def make_tag(_creator, %{} = pointable_obj, attrs) when is_map(attrs) do
    repo().transact_with(fn ->
      # TODO: check that the tag doesn't already exist (same name and parent)

      with {:ok, attrs} <- attrs_with_tag(attrs, pointable_obj),
           {:ok, tag} <- insert_tag(attrs) do
        {:ok, tag}
      end
    end)
  end

  defp attrs_with_tag(%{facet: facet} = attrs, %{} = pointable_obj) when not is_nil(facet) do
    attrs = Map.put(attrs, :prefix, prefix(attrs.facet))
    attrs = Map.put(attrs, :id, pointable_obj.id)
    # IO.inspect(attrs)
    {:ok, attrs}
  end

  defp attrs_with_tag(attrs, %{} = pointable_obj) do
    attrs_with_tag(
      Map.put(
        attrs,
        :facet,
        pointable_obj.__struct__ |> to_string() |> String.split(".") |> List.last()
      ),
      pointable_obj
    )
  end

  defp insert_tag(attrs) do
    # IO.inspect(insert_tag: attrs)
    cs = Tag.create_changeset(attrs)
    with {:ok, tag} <- repo().insert(cs), do: {:ok, tag}
  end

  # TODO: take the user who is performing the update
  def update(_user, %Tag{} = tag, attrs) do
    repo().transact_with(fn ->
      # :ok <- publish(tag, :updated)
      with {:ok, tag} <- repo().update(Tag.update_changeset(tag, attrs)) do
        {:ok, tag}
      end
    end)
  end


  def maybe_taxonomy_tag(user, id) do
    if Bonfire.Common.Config.extension_enabled?(Bonfire.TaxonomySeeder.TaxonomyTags) do
      Bonfire.TaxonomySeeder.TaxonomyTags.maybe_make_category(user, id)
    end
  end

### Functions for tagging things ###

  @doc """
  Maybe tag something
  """
  def maybe_tag(user, thing, tags \\ nil)

  def maybe_tag(user, thing, %{tags: tag_string}) when is_binary(tag_string) do
    tag_strings = Bonfire.Tag.Autocomplete.tags_split(tag_string)
    tag_something(user, thing, tag_strings)
  end

  def maybe_tag(user, thing, %{tags: tags}) when is_list(tags) and length(tags) > 0, do: tag_something(user, thing, tags)

  def maybe_tag(user, thing, tags) when is_list(tags) and length(tags) > 0, do: tag_something(user, thing, tags)

  def maybe_tag(user, thing, text) when bit_size(text) > 1 do

    tag_or_tags = Bonfire.Tag.Autocomplete.find_all_tags(text)

    case tag_or_tags do
      %{} = tag ->

        maybe_tag(user, thing, tag)

      tags when is_list(tags) and length(tags)>0 ->

        maybe_tag(user, thing, tags)

      _ ->
        # IO.inspect("no results")
        {:ok, thing}
    end
  end

  @doc """
  otherwise maybe we have tagnames inline in the note?
  """
  def maybe_tag(user, %{post_content: p}, _), do: maybe_tag(user, p, nil)
  def maybe_tag(user, %{html_body: text} = thing, _) when bit_size(text) > 1, do: maybe_tag(user, thing, text)
  def maybe_tag(user, %{summary: text} = thing, _) when bit_size(text) > 1, do: maybe_tag(user, thing, text)
  def maybe_tag(user, %{note: text} = thing, _) when bit_size(text) > 1, do: maybe_tag(user, thing, text)
  def maybe_tag(user, %{name: text} = thing, _) when bit_size(text) > 1, do: maybe_tag(user, thing, text)

  def maybe_tag(_user, thing, maybe_tags) do
    # IO.inspect(maybe_tags: maybe_tags)
    {:ok, thing}
  end


  @doc """
  tag existing thing with one or multiple Tags, Pointers, or anything that can be made into a tag
  """
  def tag_something(user, %{__struct__: _}=thing, tags) do
    with {:ok, tagged} <- do_tag_thing(user, thing, tags) do
      {:ok, Map.merge(thing, tagged)}
    end
  end

  def tag_something(user, thing, tags) do
    do_tag_thing(user, thing, tags)
  end

  @doc """
  Add tag(s) to a pointable thing. Will replace any existing tags.
  """
  defp do_tag_thing(user, thing, tags) when is_list(tags) do
    thing = thing_to_pointer(thing)
    # IO.inspect(tags: tags)
    tags = Enum.map(tags, &tag_preprocess(user, &1))
    # {:ok, thing |> Map.merge(%{tags: tag_something})}
    thing_tags_save(thing, tags)
    # Bonfire.Repo.maybe_preload(thing, :tags)
  end

  defp do_tag_thing(user, thing, tag) do
    do_tag_thing(user, thing, [tag])
  end

  @doc """
  Prepare a tag to be used, by loading or even creating it
  """
  defp tag_preprocess(_user, %Tag{} = tag) do
    tag
  end

  defp tag_preprocess(_, tag) when is_nil(tag) or tag == "" do
    nil
  end

  defp tag_preprocess(_user, {:error, e}) do
    IO.inspect(invalid_tag: e)
    nil
  end

  defp tag_preprocess(user, {_at_mention, tag}) do
    tag_preprocess(user, tag)
  end

  defp tag_preprocess(user, "@" <> tag) do
    tag_preprocess(user, tag)
  end

  defp tag_preprocess(user, "+" <> tag) do
    tag_preprocess(user, tag)
  end

  defp tag_preprocess(user, "&" <> tag) do
    tag_preprocess(user, tag)
  end

  defp tag_preprocess(user, tag) do

    with {:ok, tag} <- maybe_make_tag(user, tag) do
      # with an object that we have just made tag
      tag_preprocess(user, tag)
    else
      _e ->
        {:error, "Could not find or create such a tag or tag context"}
    end
  end

  defp thing_tags_save(%{} = thing, tags) when is_list(tags) and length(tags) > 0 do
    # remove nils
    tags = Enum.filter(tags, & &1)

    repo().transact_with(fn ->
      cs = Tag.thing_tags_changeset(thing, tags)
      with {:ok, thing} <- repo().update(cs, on_conflict: :nothing), do: {:ok, thing}
    end)
  end

  defp thing_tags_save(thing, _tags) do
    {:ok, thing}
  end

  @doc """
  Load thing as Pointer
  """
  defp thing_to_pointer(pointer_id) when is_binary(pointer_id) do
    with {:ok, pointer} <- Bonfire.Common.Pointers.one(id: pointer_id) do
      pointer
    end
  end

  defp thing_to_pointer(%Pointers.Pointer{} = pointer) do
    pointer
  end

  defp thing_to_pointer(%{id: id}) do
    thing_to_pointer(id)
  end

end
