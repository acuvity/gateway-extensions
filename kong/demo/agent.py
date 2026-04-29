# agent.py - Simple LangGraph agent with Exa search tool, routed through Kong proxy
import os
from langchain_anthropic import ChatAnthropic
from langchain_core.tools import tool
from langchain.agents import create_agent
import httpx

# LLM via Kong proxy
llm = ChatAnthropic(
    model="claude-sonnet-4-20250514",
    anthropic_api_key=os.environ["ANTHROPIC_API_KEY"],
    base_url="http://localhost:8000/anthropic",
)

# Simple Exa search tool
@tool
def exa_search(query: str) -> str:
    """Search the web using Exa AI."""
    res = httpx.post(
        "http://localhost:8000/exa/search",
        headers={"x-api-key": os.environ["EXA_API_KEY"]},
        json={"query": query, "num_results": 3, "type": "neural"},
        timeout=30,
    )
    results = res.json().get("results", [])
    return "\n\n".join(f"**{r['title']}**\n{r['url']}" for r in results) or "No results found."

# Create agent
agent = create_agent(llm, [exa_search])

# Run
result = agent.invoke({"messages": [{"role": "user", "content": "can you give me some engineering fields"}]})
for msg in result["messages"]:
    print(f"\n[{msg.type}]: {msg.content}")