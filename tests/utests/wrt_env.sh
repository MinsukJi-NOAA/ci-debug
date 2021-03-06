cat <<EOF >${RUNDIR_ROOT}/unit_test${RT_SUFFIX}.env
export UNIT_TEST=${UNIT_TEST}
export CI_TEST=${CI_TEST}
export RT_COMPILER=${RT_COMPILER}
export FHMAX=${FHMAX}
export DAYS=${DAYS}
export RESTART_INTERVAL=${RESTART_INTERVAL}
export INPES=${INPES}
export JNPES=${JNPES}
export NPROC_ICE=${NPROC_ICE:-}
export med_petlist_bounds="${med_petlist_bounds:-}"
export atm_petlist_bounds="${atm_petlist_bounds:-}"
export ocn_petlist_bounds="${ocn_petlist_bounds:-}"
export ice_petlist_bounds="${ice_petlist_bounds:-}"
export THRD=${THRD}
export TASKS=${TASKS}
export TPN=${TPN}
export NODES=${NODES}
export MPI_PROC_BIND="${MPI_PROC_BIND:-}"
EOF
