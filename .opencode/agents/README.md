# Game Studio Sub-Agents Directory

## Agent Hierarchy

```
Master Orchestrator (System Controller)
    └── Producer Agent (Project Manager)
            ├── Market Analyst (Competitive Intelligence)
            ├── Data Scientist (Analytics & Metrics)
            ├── Sr Game Designer (Design Lead)
            │     └── Mid Game Designer (Content Creator)
            ├── Mechanics Developer (Core Systems)
            │     └── Game Feel Developer (Polish)
            ├── Sr Game Artist (Art Director)
            │     ├── Technical Artist (Implementation)
            │     └── UI/UX Agent (Interface)
            └── QA Agent (Quality Assurance)
```

## Active Agents

### Management Layer
- **master_orchestrator.md** - System coordinator and project initialization
- **producer_agent.md** - Project management and production control

### Intelligence Layer
- **market_analyst.md** - Competitive analysis and market intelligence
- **data_scientist.md** - Analytics, metrics, and predictive modeling

### Design Team
- **sr_game_designer.md** - Vision holder and systems architect
- **mid_game_designer.md** - Content creation and implementation specs

### Engineering Team  
- **mechanics_developer.md** - Core gameplay systems and architecture
- **game_feel_developer.md** - Polish, feedback, and game juice

### Art Team
- **sr_game_artist.md** - Art direction and visual style
- **technical_artist.md** - Shaders, VFX, and optimization
- **ui_ux_agent.md** - User interface and experience design

### Quality Assurance
- **qa_agent.md** - Testing, validation, and quality control

## Agent Activation

Agents are activated based on project mode:

### Design Mode
- Master Orchestrator
- Producer Agent
- Market Analyst
- Data Scientist
- Sr Game Designer
- Mid Game Designer  
- Sr Game Artist

### Prototype Mode
- Master Orchestrator
- Producer Agent
- Market Analyst
- Data Scientist
- Sr Game Designer
- Mechanics Developer
- QA Agent

### Development Mode
- All agents activated (12 total)

## Communication Flow

1. **User** → **Master Orchestrator** (project request)
2. **Master Orchestrator** → **Producer Agent** (project setup)
3. **Producer Agent** → **Specialized Agents** (task distribution)
4. **Specialized Agents** → **Producer Agent** (deliverables)
5. **Producer Agent** → **Master Orchestrator** (status updates)
6. **Master Orchestrator** → **User** (project delivery)

## Usage

To start a new project:
```bash
python scripts/init_project.py
```

Then activate the Master Orchestrator:
```bash
claude "Read agents/master_orchestrator.md and initialize project [name]"
```

## Agent Prompting Best Practices

1. Always read the specific agent file before activation
2. Provide clear project context
3. Reference the project-config.json
4. Use structured commands from agent documentation
5. Follow the established communication protocols

## Version History

- v2.0 - Production-ready with Master Orchestrator
- v1.0 - Initial agent templates (deprecated - see /archive)