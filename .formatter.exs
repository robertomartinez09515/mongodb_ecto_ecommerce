# Used by "mix format"
[
  inputs: [
    "mix.exs",
    ".formatter.exs",
    "{lib,test,examples}/**/*.{ex,exs}"
  ],
  locals_without_parens: [
    # Query
    from: 2,

    # Schema
    field: 1,
    field: 2,
    field: 3,
    timestamps: 0,
    timestamps: 1,
    belongs_to: 2,
    belongs_to: 3,
    has_one: 2,
    has_one: 3,
    has_many: 2,
    has_many: 3,
    many_to_many: 2,
    many_to_many: 3,
    embeds_one: 2,
    embeds_one: 3,
    embeds_one: 4,
    embeds_many: 2,
    embeds_many: 3,
    embeds_many: 4,

    # Test assertion
    assert_fields: 2
  ]
]
