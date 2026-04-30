# agent.py - Simple LangGraph agent with Exa search tool, routed through Kong proxy
import os
from langchain_openai import ChatOpenAI
from langchain_core.tools import tool
from langchain.agents import create_agent
import httpx

KONG_AI_GATEWAY_URL = os.environ.get("KONG_AI_GATEWAY_URL", "http://localhost:8000")
SSL_VERIFY = os.environ.get("SSL_VERIFY", "true").lower() == "true"

# LLM via Kong proxy (Kong's AI Gateway normalizes Anthropic responses to OpenAI format)
llm = ChatOpenAI(
    model="claude-sonnet-4-5",
    api_key=os.environ["ANTHROPIC_API_KEY"],
    base_url=KONG_AI_GATEWAY_URL,
    http_client=httpx.Client(verify=SSL_VERIFY),
)

# Create agent
agent = create_agent(llm)

# Run
result = agent.invoke({"messages": [{"role": "user", "content": "give me fields in engieneering?"}]})
for msg in result["messages"]:
    print(f"\n[{msg.type}]: {msg.content}")