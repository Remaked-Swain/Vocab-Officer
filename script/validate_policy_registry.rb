#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

class SchemaValidationError < StandardError; end

def schema_type?(value, type)
  case type
  when "object" then value.is_a?(Hash)
  when "array" then value.is_a?(Array)
  when "string" then value.is_a?(String)
  when "integer" then value.is_a?(Integer)
  when "boolean" then value == true || value == false
  else false
  end
end

def resolve_reference(root_schema, reference)
  prefix = "#/"
  raise SchemaValidationError, "unsupported schema reference #{reference}" unless reference.start_with?(prefix)

  reference.delete_prefix(prefix).split("/").reduce(root_schema) do |value, component|
    value.fetch(component.gsub("~1", "/").gsub("~0", "~"))
  end
rescue KeyError
  raise SchemaValidationError, "unresolved schema reference #{reference}"
end

def validate_schema(value, schema, root_schema, location = "$")
  if schema.key?("$ref")
    return validate_schema(value, resolve_reference(root_schema, schema.fetch("$ref")), root_schema, location)
  end

  if schema.key?("type") && !schema_type?(value, schema.fetch("type"))
    raise SchemaValidationError, "#{location}: expected #{schema.fetch("type")}"
  end
  if schema.key?("const") && value != schema.fetch("const")
    raise SchemaValidationError, "#{location}: expected constant #{schema.fetch("const").inspect}"
  end
  if schema.key?("enum") && !schema.fetch("enum").include?(value)
    raise SchemaValidationError, "#{location}: value is outside the enum"
  end
  if value.is_a?(String) && value.length < schema.fetch("minLength", 0)
    raise SchemaValidationError, "#{location}: string is too short"
  end
  if value.is_a?(Array)
    raise SchemaValidationError, "#{location}: array is too short" if value.length < schema.fetch("minItems", 0)
    if schema["uniqueItems"] && value.uniq.length != value.length
      raise SchemaValidationError, "#{location}: array items must be unique"
    end
    value.each_with_index do |item, index|
      validate_schema(item, schema.fetch("items", {}), root_schema, "#{location}[#{index}]")
    end
  end
  return unless value.is_a?(Hash)

  raise SchemaValidationError, "#{location}: object has too few properties" if value.length < schema.fetch("minProperties", 0)
  schema.fetch("required", []).each do |key|
    raise SchemaValidationError, "#{location}: missing required property #{key}" unless value.key?(key)
  end
  properties = schema.fetch("properties", {})
  if schema["additionalProperties"] == false
    extras = value.keys - properties.keys
    raise SchemaValidationError, "#{location}: unexpected properties #{extras.join(", ")}" unless extras.empty?
  end
  value.each do |key, child|
    child_schema = properties[key]
    child_schema ||= schema["additionalProperties"] if schema["additionalProperties"].is_a?(Hash)
    validate_schema(child, child_schema, root_schema, "#{location}.#{key}") if child_schema
  end
end

def expect_invalid(schema, registry, description)
  validate_schema(registry, schema, schema)
  abort("schema self-test accepted #{description}")
rescue SchemaValidationError
  nil
end

begin
schema_path, registry_path, mode = ARGV
abort("usage: validate_policy_registry.rb <schema> <registry> [--self-test]") unless schema_path && registry_path

schema = JSON.parse(File.read(schema_path))
registry = JSON.parse(File.read(registry_path))
validate_schema(registry, schema, schema)

if mode == "--self-test"
  mutation = Marshal.load(Marshal.dump(registry))
  mutation["unexpected"] = true
  expect_invalid(schema, mutation, "an extra top-level property")

  mutation = Marshal.load(Marshal.dump(registry))
  mutation.fetch("rules").first["audit"] = "optional"
  expect_invalid(schema, mutation, "an invalid audit value")

  mutation = Marshal.load(Marshal.dump(registry))
  mutation.fetch("rules").first["evidence"] = "forever"
  expect_invalid(schema, mutation, "an invalid evidence value")

  mutation = Marshal.load(Marshal.dump(registry))
  mutation.fetch("alwaysRequired") << mutation.fetch("alwaysRequired").first
  expect_invalid(schema, mutation, "duplicate document values")

  mutation = Marshal.load(Marshal.dump(registry))
  mutation.fetch("rules").find { |rule| !rule.fetch("conditional").empty? }.fetch("conditional").first.delete("when")
  expect_invalid(schema, mutation, "a malformed condition")

  mutation = Marshal.load(Marshal.dump(registry))
  mutation["tasks"] = []
  expect_invalid(schema, mutation, "a non-object task catalog")

  puts "Policy registry schema self-test passed."
else
  puts "Policy registry conforms to schema."
end
rescue JSON::ParserError, Errno::ENOENT, SchemaValidationError => error
  warn(error.message)
  exit(1)
end
