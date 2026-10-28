"""The analyst's model turn, shared by every Subagent security sample.

The trusted controller has already produced a verified comparison by the time this runs.
The model's job is to explain that comparison and cite the originals, not to decide the
winner: it gets one tool, which returns the verified facts, and it returns a structured
answer whose supplier choice the controller then checks against those facts.

The call uses Amazon Bedrock through Strands Agents with the pod's EKS Pod Identity
credentials. No model API key is placed in the sandbox, and nothing here reads one.
"""
import os

from strands import Agent, tool
from strands.models import BedrockModel
from pydantic import BaseModel, Field

SYSTEM_PROMPT = (
    "You are a procurement analyst. Call procurement_evidence before answering. Compare "
    "every supplier against the budget, delivery and warranty requirements it returns. "
    "Recommend only a supplier the evidence marks eligible. Cite each supplier's S3 "
    "source key, exactly as the evidence gives it, in your analysis. Do not place orders "
    "and do not propose changing a supplier record. Write a concise Markdown analysis. "
    "Put the supplier id you select in recommended_supplier: the application renders the "
    "recommendation heading from that field, not from your prose."
)


class ProcurementReport(BaseModel):
    """The structured answer the controller gates on."""

    recommended_supplier: str = Field(
        description="Exact supplier id selected from the verified comparison")
    analysis_markdown: str = Field(
        description="Concise comparison citing every original S3 proposal source key")


class ModelTurn:
    """One Bedrock turn over a verified comparison.

    Attributes after run():
      report       the structured answer as a dict, or None if the model returned none
      usage        Bedrock's accumulated token usage for the turn
      tool_calls   how many times the model actually called the evidence tool
    """

    def __init__(self, case: dict, comparison: dict, model_id=None, region=None,
                 max_tokens=2000):
        self.case = case
        self.comparison = comparison
        self.model_id = model_id or os.environ["BEDROCK_MODEL_ID"]
        self.region = region or os.environ["AWS_REGION"]
        self.max_tokens = max_tokens
        self.report = None
        self.usage = {}
        self.tool_calls = 0

    def _evidence_tool(self):
        turn = self

        @tool
        def procurement_evidence() -> dict:
            """Get the verified supplier comparison, the requirements and the original
            document citations for this procurement case."""
            turn.tool_calls += 1
            return {"requirements": turn.case["requirements"], **turn.comparison}

        return procurement_evidence

    def run(self) -> dict:
        agent = Agent(
            model=BedrockModel(model_id=self.model_id, region_name=self.region,
                               max_tokens=self.max_tokens),
            tools=[self._evidence_tool()],
            callback_handler=None,
            system_prompt=SYSTEM_PROMPT,
        )
        answer = agent(f"Prepare a recommendation for {self.case['description']}.",
                       structured_output_model=ProcurementReport)
        self.usage = dict(answer.metrics.accumulated_usage)
        if isinstance(answer.structured_output, ProcurementReport):
            self.report = answer.structured_output.model_dump()
        return self.report
