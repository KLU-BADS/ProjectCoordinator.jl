using ProjectCoordinator
using Test

@testset "ProjectCoordinator" begin
    @testset "config" begin
        @test_broken false   # course_dir, load_course, expand
    end

    @testset "create" begin
        @test_broken false   # dry run produces the expected calls
    end
end
