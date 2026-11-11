import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("contract", pathlib.Path(__file__).with_name("contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class EventDefinitionsTests(unittest.TestCase):
    def test_reuses_canonical_definition_and_rejects_conflicts(self):
        schemas = {"Block": {"type": "object", "properties": {"text": {"type": "string"}}}}
        event = {"$defs": {"Block": {"type": "object", "additionalProperties": True,
                                    "properties": {"text": {"type": "string"}}}},
                 "properties": {"block": {"$ref": "#/$defs/Block"}}}
        result = contract.lift_event_definitions(event, "Event", schemas)
        self.assertEqual(result["properties"]["block"]["$ref"], "#/components/schemas/Block")
        self.assertEqual(list(schemas), ["Block"])
        with self.assertRaisesRegex(ValueError, "conflicts"):
            contract.lift_event_definitions({"$defs": {"Block": {"type": "number"}}}, "Event", schemas)

    def test_only_refs_are_rewritten_and_pointer_suffix_and_escaping_are_preserved(self):
        event = {"$defs": {"A/B~C": {"type": "object", "properties": {"x": {"type": "string"}}}},
                 "description": "#/$defs/A~1B~0C",
                 "const": "#/$defs/A~1B~0C/properties/x",
                 "properties": {"x": {"$ref": "#/$defs/A~1B~0C/properties/x"}}}
        schemas = {}
        result = contract.lift_event_definitions(event, "Event", schemas)
        self.assertEqual(result["description"], "#/$defs/A~1B~0C")
        self.assertEqual(result["const"], "#/$defs/A~1B~0C/properties/x")
        self.assertEqual(result["properties"]["x"]["$ref"], "#/components/schemas/EventA~1B~0C/properties/x")
        self.assertIn("EventA/B~C", schemas)


if __name__ == "__main__":
    unittest.main()
