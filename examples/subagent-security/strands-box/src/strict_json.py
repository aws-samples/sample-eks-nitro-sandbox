"""Decode sample inputs without silently replacing repeated object fields."""
import json


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            # Do not echo arbitrary input values or keys into diagnostics.
            raise ValueError("Duplicate JSON object key")
        result[key] = value
    return result


def loads(document):
    return json.loads(document, object_pairs_hook=unique_object)


def load(stream):
    return loads(stream.read())
