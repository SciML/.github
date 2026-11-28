using Test

@testset "Workflow test group" begin
    group = get(ENV, "GROUP", "")
    custom_group = get(ENV, "SCIML_WORKFLOW_TEST_GROUP", "")
    selected_group = isempty(custom_group) ? group : custom_group
    println("GROUP=", repr(group))
    println("SCIML_WORKFLOW_TEST_GROUP=", repr(custom_group))
    println("Selected test group=", repr(isempty(selected_group) ? "All" : selected_group))
    @test selected_group == "Core"
end
